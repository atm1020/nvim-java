local JavaDap = require('java.dap')
local async = require('java-core.utils.async').sync
local get_error_handler = require('java.handlers.error')
local log = require('java-core.utils.log')
local DapSetup = require('java-dap.api.setup')
local buf_util = require('java.utils.buffer')
local class = require('java-core.utils.class')
local data_adapters = require('java-core.adapters')
local JUnitReport = require('java-test.reports.junit')
local ResultParserFactory = require('java-test.results.result-parser-factory')
local ReportViewer = require('java-test.ui.floating-report-viewer')
local nio = require('nio')

local function jdtls()
	local clients = vim.lsp.get_active_clients({ name = 'jdtls' })

	if #clients > 1 then
		error('Could not find any running jdtls clients')
	end

	return clients[1]
end

--- @class NeoTestJdtlsAdapter
--- @field private client LspClient
--- @field private dap JavaCoreDap
--- @field neotest_adapter neotest.Adapter
--- @filed name string
local NeoTestJdtlsAdapter = class()

function NeoTestJdtlsAdapter:_init(client)
	self.client = client
	self.dap = DapSetup(client)
	self.neotest_adapter = {
		name = 'neotest-jdtls',
	}
end

local M = {}
M.is_initialized = false

function M:_init()
	M.client = async(function()
			return jdtls()
		end)
		.catch(get_error_handler('failed to run app'))
		.run()
	M.dap = DapSetup(M.client)
	M.is_initialized = true
end

function M.get_lsp_client()
	local clients = vim.lsp.get_active_clients({ name = 'jdtls' })

	if #clients < 1 then
		error('Jdtls client not found')
	end

	return clients[1]
end

---Executes workspace command on jdtls
---@param cmd_info {command: string, arguments: any }
---@param timeout number?
---@param buffer number?
---@return { err: { code: number, message: string }, result: any }
local function execute_command(cmd_info, timeout, buffer)
	timeout = timeout and timeout or 5000
	buffer = buffer and buffer or 0
	return jdtls().request_sync(
		'workspace/executeCommand',
		cmd_info,
		timeout,
		buffer
	)
end

local neotest = {}

---@class neotest.Adapter
---@field name string
neotest.Adapter = {}

local lib = require('neotest.lib')
---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
function neotest.Adapter.root(dir)
	local root = jdtls().config.root_dir
	log.error('root: ' .. root)
	return root
end

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
function neotest.Adapter.filter_dir(name, rel_path, root)
	log.info('filter_dir: ', name, rel_path, root)
	if string.find(rel_path, 'test') then
		return true
	end
	if name == 'src' or name == 'test' then
		if name == rel_path then
			 return true
		elseif string.find(rel_path, 'test') then
			return true
		end
	end
	return false
end

---@async
---@param file_path string
---@return boolean
function neotest.Adapter.is_test_file(file_path)
	local is_test_file = string.find(file_path, 'Test') ~= nil
		and string.find(file_path, '.java') ~= nil
	-- log.info(file_path,'is_test_file: ', is_test_file, "test_info: ", vim.inspect(test_info) )
	return is_test_file
end

local lib = require('neotest.lib')
---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function neotest.Adapter.discover_positions(file_path)
	local query = [[
       ;; Test class
        (class_declaration
          name: (identifier) @namespace.name
        ) @namespace.definition

      ;; @Test and @ParameterizedTest functions
      (method_declaration
        (modifiers
          (marker_annotation
            name: (identifier) @annotation
              (#any-of? @annotation "Test" "ParameterizedTest" "CartesianTest")
            )
        )
        name: (identifier) @test.name
      ) @test.definition

    ]]
	return lib.treesitter.parse_positions(
		file_path,
		query,
		{ nested_namespaces = true }
	)
end

local function setup(server, dap_launcher_config, report)
	server:bind('127.0.0.1', 0)
	server:listen(128, function(err)
		assert(not err, err)
		local sock = assert(vim.loop.new_tcp(), 'uv.new_tcp must return handle')
		server:accept(sock)
		local success = sock:read_start(report:get_stream_reader(sock))
		assert(success == 0, 'failed to listen to reader')
	end)
	dap_launcher_config.args = dap_launcher_config.args:gsub(
		'-port ([0-9]+)',
		'-port ' .. server:getsockname().port
	)
	return dap_launcher_config
end

---@param args neotest.RunArgs
---@return neotest.RunSpec
function neotest.Adapter.build_spec(args)
	local strategy = args.strategy
	local tree = args and args.tree
	local pos = tree:data()

	local resolved_main_class = execute_command({
		command = 'vscode.java.resolveMainClass',
		arguments = nil,
	}).result[1]

	log.info('257')
	local main_class = resolved_main_class.mainClass
	local project_name = resolved_main_class.projectName
	local file_uri = resolved_main_class.filePath
	local ff = buf_util.get_curr_uri()

	local data = tree:data()
	file_uri = 'file://' .. data.path

	local executable = execute_command({
		command = 'vscode.java.resolveJavaExecutable',
		arguments = { main_class, project_name },
	})

	local test_types_and_methods = execute_command({
		command = 'vscode.java.test.findTestTypesAndMethods',
		arguments = { file_uri },
	})

	log.info('test_method_stuff: ', vim.inspect(test_types_and_methods))
	-- log.info(vim.inspect(args))
	-- for key, value in ipairs(tree) do
	log.info('>>>>>> tree: ', vim.inspect(tree.data))
	local inpust = {}
	log.info('data', vim.inspect(data))
	log.info('id: ', data.id)
	log.info('id: ', data.path)
	log.info('type:', data.type)

	log.info('range ', data.range)
	local start_line = data.range[1] + 1
	local end_line = data.range[3]
	log.info('start_line: ', start_line)
	log.info('end_line: ', end_line)
	local m = nil
	local idl = {}
	if data.type == 'test' then
		for _, cls in ipairs(test_types_and_methods.result) do
			for _, method in ipairs(cls.children) do
				log.info(vim.inspect(method))
				if method.range.start.line == start_line then
					m = method
					break
				end
				m = method
			end
		end
		idl = {
			projectName = m.projectName,
			testLevel = m.testLevel,
			testKind = m.testKind,
			testNames = { m.jdtHandler },
		}
	elseif data.type == 'file' or data.type == 'namespace' then
		local testNames = {}
		-- local m = nil
		for _, cls in ipairs(test_types_and_methods.result) do
			for _, method in ipairs(cls.children) do
				table.insert(testNames, method.jdtHandler)
				if m == nil then
					m = method
				end
			end
		end
		idl = {
			projectName = m.projectName,
			testLevel = 5,
			testKind = m.testKind,
			testNames = { 'com.example.demo.DemoApplicationTests' },
		}
	end

	log.info('idl: ', vim.inspect(idl))

	local junit_arguments = execute_command({
		command = 'vscode.java.test.junit.argument',
		arguments = vim.fn.json_encode(idl),
	}).result.body

	local is_debug = strategy == 'dap'
	local dap_launcher_config =
		data_adapters.get_dap_launcher_config(junit_arguments, executable.result, {
			debug = is_debug,
			label = 'Launch All Java Tests',
		})

	local report = JUnitReport(ResultParserFactory(), ReportViewer())
	local server = assert(vim.loop.new_tcp(), 'uv.new_tcp() must return handle')
	dap_launcher_config = setup(server, dap_launcher_config, report)

	local config = {}
	if not is_debug then
		local event = nio.control.event()
		vim.schedule(function()
			require('dap').run(dap_launcher_config, {
				after = function()
					if server then
						server:shutdown()
						server:close()
						log.info('server closed')
						log.info('conf', vim.inspect(dap_launcher_config))
					end
					event.set()
				end,
			})
		end)
		event.wait()
		log.info('350')
	else
		dap_launcher_config.after = function()
			vim.schedule(function()
				if server then
					server:shutdown()
					server:close()
					log.info('server closed')
				end
			end)
		end
		config = dap_launcher_config
	end

	local context = {
		file = pos.path,
		pos_id = pos.id,
		type = pos.type,
		report = report,
	}
	local response = {
		-- command = table.concat(cmd, ' '),
		cwd = junit_arguments.workingDirectory,
		symbol = m.name,
		context = context,
		strategy = config,
		-- dap= { adapter_name = "netcoredbg" }
	}
	log.info('>>>>>>>>>>>>>> build_spec return')
	return response
end

local TestStatus = {
	Failed = 'failed',
	Skipped = 'skipped',
}

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function neotest.Adapter.results(spec, result, tree)
	local result_map = {}
	local report = spec.context.report:get_results()
	for _, tm in ipairs(report) do
		for _, ch in ipairs(tm.children) do
			local key = vim.split(ch.display_name, '%(')[1]
			local value = {}
			if ch.result.status == TestStatus.Failed then
				value = {
					status = 'failed',
					errors = {
						{ message = table.concat(ch.result.trace, '\n') },
					},
					short = ch.result.trace[1],
				}
			elseif ch.result.status == TestStatus.Skipped then
				value = {
					status = 'skipped',
				}
			else
				value = {
					status = 'passed',
				}
			end
			log.info('key: ', key, ' value: ', vim.inspect(value))
			result_map[key] = value
		end
	end
	local res = {}

	for _, node in tree:iter_nodes() do
		local data = node:data()
		local rr = result_map[data.name]
		if rr then
			log.info('node: ', vim.inspect(data), vim.inspect(result_map[data.name]))
			data.status = rr.status
			res[data.id] = {
				status = rr.status,
			}
			if rr.errors then
				res[data.id].errors = rr.errors
				res[data.id].short = rr.short
			end
		end
	end
	return res
end

setmetatable(neotest.Adapter, {
	__call = function()
		return neotest.Adapter
	end,
})

return neotest.Adapter
