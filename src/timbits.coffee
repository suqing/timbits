express = require 'express'
pantry = require 'pantry'
fs = require 'fs'
path = require 'path'
request = require 'request'
connectESI = require 'connect-esi'
ck = require 'coffeekup'
Log = require 'coloured-log'
views = require './timbits-views'

config = { appName: "Timbits", engine: "coffee", port: 5678, home: process.cwd() }
server = {}

log = new Log()

# creates, configures, and returns a standard express server instance
@serve = (options) ->
	config[key] = value for key, value of options
	@server = express.createServer()

	log = new Log(if @server.settings.env is 'development' then Log.DEBUG else Log.INFO)

	# support coffekup
	@server.register '.coffee', ck

	# configure server (still needs some thought)
	@server.set 'views', "#{config.home}/views"
	@server.set 'view engine', config.engine
	@server.set 'view options', {layout: false}

	@server.configure =>
		@server.use connectESI.setupESI()
		@server.use express.static("#{config.home}/public")
		@server.use express.static("#{config.home}/views")
		@server.use express.static(path.join(path.dirname(__filename),"../resources"))
		@server.use express.bodyParser()
		@server.use express.cookieParser()

	@server.configure 'development', =>
		@server.use express.errorHandler({ dumpExceptions: true, showStack: true })

	@server.configure 'production', =>
		@server.use express.errorHandler()

	# route root to help page
	@server.get '/', (req, res) ->
		res.redirect '/timbits/help'

	# route help page
	@server.get '/timbits/help', (req, res) =>
		res.send ck.render(views.help, @box)

	# route master test page
	@server.get '/timbits/test', (req, res) =>
		res.setHeader 'Content-Type', 'text/html; charset=UTF-8'
		master = ''
		pending = Object.keys(@box).length
		for timbit of @box
			request {uri: "http://#{server.address}:#{server.port}/#{timbit}/test" }, (error, response, body) ->
				master += body
				res.end master unless --pending

	# automagically load timbits found in the ./timbits folder
	path = "#{config.home}/timbits"
	fs.readdir path, (err, files) =>
		throw err if err
		for file in files
			if file.match(/\.(coffee|js)$/)?
				@add file.substring(0, file.lastIndexOf(".")), require("#{path}/#{file}")

	# starts the server
	@server.listen process.env.PORT || process.env.C9_PORT || config.port
	log.info "Timbits server listening on port #{@server.address().port} in #{@server.settings.env} mode"
	server.address = @server.address().address
	server.port = @server.address().port
	@server

# the box that holds each of the individual timbits created
@box = {}

# use the 'add' method to place a timbit in the box
@add = (name, timbit) ->
	#place the timbit in the box
	log.notice "Placing #{name} in the box"
	timbit.name = name
	timbit.view_base ?= name
	@box[name] = timbit

	# configure help
	@server.get ("/#{name}/help"), (req, res) ->
		res.send ck.render(views.timbit_help, timbit)

	# configure test
	@server.get ("/#{name}/test"), (req, res) ->
		timbit.test server, timbit, (results) ->
			res.send ck.render(views.timbit_test, results)

	# configure the route
	@server.get ("/#{name}/:view?"), (req, res) ->
		try
			# initialize current request context
			context = {}
			context[k] = v for k,v of req.query

			context.name = timbit.name
			context.view = "#{timbit.view_base}/#{req.params.view ?= 'default'}"

			# validate the request
			for key, attr of timbit.params
				context[key] ?= attr.default
				value = context[key]

				if attr.required and not value
					throw "#{key} is a required parameter"

				if value and attr.strict and attr.values.indexOf(value) is -1
					throw "#{value} is not a valid value for #{key}.  Must be one of [#{attr.values.join()}]"

				if value instanceof Array and not attr.multiple
					throw "#{key} must be a single value"

			# with context created, it's time to consume this timbit
			timbit.eat req, res, context
		catch ex
			log.error "#{req.url} - #{ex}"
			throw ex

# definition of a timbit
class @Timbit

	# default render implementation
	render: (req, res, context) ->
		if context.remote is 'true'
			output = """
					$().ready(function() {
						return $.get("/#{context.view}.coffee", function(data) {
							context = #{JSON.stringify(context)};
							return $('##{context.timbit_id}').html(CoffeeKup.render(data, context));
						});
					});
			"""
			res.setHeader "Content-Type", "text/plain"
			res.write output
			res.end()
		else
			res.render context.view, context

	# helper method to retrieve data via REST
	fetch: (req, res, context, options, callback = @render) ->

		name = options.name or 'data'
		pantry.fetch options, (error, results) =>
			context[name] = results

			# we're done, will now execute rendor method unless otherwise specified
			callback(req, res, context)

	# this is the method executed after a matching route.  overwritten on most implementations
	eat: (req, res, context) ->
		@render req, res, context

	test: (server, context, callback) ->
		results = {
			timbit: context.name
			views: []
			required: []
			optional: []
			queries: []
			tests: []
			warnings: []
		}

		testViews = (callback) ->
			# Retrieve list of views from the views directory for this timbit
			fs.readdir "#{config.home}/views/#{context.name}", (err,list) ->
				if err || list is undefined
					results.warnings.push { message: "Unable to retrieve a list of views" }
					results.views.push 'default' # We will attempt the default view anyway and hope the timbit knows what it is doing.
				else
					for file in list then do (file) ->
						if file.match(/\.coffee/)?
							results.views.push (require('path').basename(file, '.coffee'))
				callback()

		testParams = ->
			# Process parameters, seperate into required vs. optional
			for k, v of context.params
				param = "#{k}=#{v.values[0]}"
				if v.required
					results.required.push param
				else
					results.optional.push param

		testQueries = ->
			# Determine whether we have optional and required parameters and build query strings.
			results.queries.push "#{results.required.concat(results.optional).join('&')}"

		testRequest = (type, uri, callback) ->
			# Execute request for uri and store result
			request {uri: "#{uri}" }, (error, response, body) ->
				results.tests.push { type: type, uri: uri, status: response.statusCode, error: (if error? then error else '') }
				callback()

		testRunQueries = (callback) ->
			if results.queries?.length is 0
				# Test each view if no query parameters present
				pending = results.views.length
				for view in results.views then do (view) ->
					testRequest "views", "http://#{server.address}:#{server.port}/#{context.name}/#{view}", ->
						callback() unless --pending
			else
				# Test each query for each view
				pending = results.queries.length * results.views.length
				for query in results.queries then do (query) ->
					for view in results.views then do (view) ->
						testRequest "queries", "http://#{server.address}:#{server.port}/#{context.name}/#{view}?#{query}", ->
							callback() unless --pending

		testRunExamples = (callback) ->
			# Test the example links provided.
			if context.examples?
				pending = context.examples.length
				for example in context.examples then do (example) ->
					testRequest "example", "http://#{server.address}:#{server.port}#{example.href}", ->
						callback() unless --pending
			else
			 	callback()

		runTests = ->
			# Execute the tests based on provided querystrings, views and examples.
			testViews ->
				testParams()
				testQueries()
				testRunQueries ->
					testRunExamples ->
						displayTests()

		displayTests = ->
			log.notice "Testing Timbit - #{context.name}"
			for test in results.tests
				if test.status >= 400 or error?
					log.error "Test: #{test.type} URI: #{test.uri} Status: #{test.status} Error: #{test.error}"
				else
					log.info "Test: #{test.type} URI: #{test.uri} Status: #{test.status}"
			for warning in results.warnings
					log.warning "Message: #{warning.message}"
			callback results

		runTests()