assert = require('chai').assert
helper = require './test-helper'
http   = require 'http'
crypto = require 'crypto'
fs     = require 'fs'

describe '/rpc list', ->
  beforeEach (done) ->
    process.env.RPC_PRIVATE_KEY = fs.readFileSync("test/hubot-test.pem")
    process.env.RPC_PUBLIC_KEY = fs.readFileSync("test/hubot-test.pub")
    @server = http.createServer()
    @sockets = {}
    @nextSocketId = 0

    @chatopListing =
      namespace: "deploy"
      help: "generic help about deployments\ntwo lines of it"
      methods:
        wcid:
          help: "where can i deploy?"
          regex: "(?:where can i deploy|wcid)(?: (?<app>\\S+))?",
          params: ["app", "generic_argument", "argument2"]
          path: "wcid"

    # Listen on localhost on a unique port.
    @server.listen =>
      @serverURL = "http://localhost:#{@server.address().port}"

      @robot = helper.robot()
      @user = helper.testUser @robot
      @robot.adapter.on 'connected', ->
        @robot.loadFile helper.SCRIPTS_PATH, "chatops-rpc.coffee"
        @robot.brain.emit 'loaded'
        done()
      @robot.run()

    @chatopsUrl = "http://localhost:#{@server.address().port}/_chatops"
    @server.on 'connection', (socket) =>
      socketId = @nextSocketId++
      @sockets[socketId] = socket
      socket.on 'close', () =>
        delete @sockets[socketId]


  afterEach (done) ->
    @robot.shutdown()
    for _, socket of @sockets
      socket.destroy()
    @server.close done

  defaultServerResponder = (chatopListing) ->
    return (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        jsonrpcResponse =
          jsonrpc: "2.0",
          id: null,
          result: "foo response!"
        body = []
        request.on 'data', (chunk) ->
          body.push chunk
        .on 'end', ->
          body = Buffer.concat(body).toString()
          data = JSON.parse(body)
          if data.params.generic_argument? || data.params.boolean_arg?
            app = if data.params.app? then ", app was #{data.params.app}" else ", app is empty"
            arg2 = if data.params.argument2? then ", arg2 is #{data.params.argument2}" else ""
            bool = if data.params.boolean_arg? then ", boolean arg was #{data.params.boolean_arg}" else ""
            jsonrpcResponse.result = "a generic argument of #{data.params.generic_argument} was sent#{arg2}#{bool}#{app}"
          else if data.params.app?
            jsonrpcResponse.result = "foo response about #{data.params.app}!"
          response.write JSON.stringify(jsonrpcResponse)
          response.end()
      else
        error = new Error "Should not have received request: #{request.method} #{request.url}"
        response.end()

  it 'adds a server', (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/wcid", (envelope, response) =>
          assert.include response, "foo response!"
          helper.converse @robot, @user, "/rpc list", (envelope, response) =>
            assert.include response, "Endpoint - Updated - Last response\n#{@chatopsUrl} -"
            helper.converse @robot, @user, "/wcid foobar", (envelope, response) =>
              assert.include response, "foo response about foobar!"
              done(error)

  it 'parses generic key value arguments', (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/wcid --generic_argument something with spaces", (envelope, response) =>
          assert.include response, "a generic argument of something with spaces was sent, app is empty"
          helper.converse @robot, @user, "/wcid github --generic_argument something with spaces", (envelope, response) =>
            assert.include response, "a generic argument of something with spaces was sent, app was github"
            helper.converse @robot, @user, "/wcid github --boolean_arg --generic_argument something with spaces --argument2 is also here", (envelope, response) =>
              assert.include response, "a generic argument of something with spaces was sent, arg2 is is also here, boolean arg was true, app was github"
              helper.converse @robot, @user, "/wcid github --boolean_arg", (envelope, response) =>
                assert.include response, "a generic argument of undefined was sent, boolean arg was true, app was github"
                done(error)

  it 'supports a "raw" mode', (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/rpc raw foo.bar", (envelope, response) =>
          assert.include response, "I couldn't find a method called foo.bar"
          helper.converse @robot, @user, "/rpc raw deploy.wcid --app foo-app --generic_argument has spaces here too", (envelope, response) =>
            assert.include response, "a generic argument of has spaces here too was sent, app was foo-app"
            done(error)

  it 'reports server errors', (done) ->
    # by default, log messages end up in the test output. UGH
    @robot.logger.level = 'ERROR'
    error = null
    chatopListing = @chatopListing
    @server.on 'request', (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        response.statusCode = 500
        response.write("This isn't even JSON!")
        response.end()
    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/wcid foobar", (envelope, response) =>
          assert.include response, "Error: This isn't even JSON!"
          helper.converse @robot, @user, "", (envelope, response) =>
            throw new Error("An extra message was sent after the error notification.")
          done(error)


  it 'sends the HMAC auth signature', (done) ->
    @robot.logger.level = 'ERROR'
    error = null
    chatopListing = @chatopListing
    @server.on 'request', (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        message = ("#{request.headers["chatops-nonce"]}~#{request.headers["chatops-timestamp"]}~#{request.headers["chatops-signature"]}")
        data = { result: message }
        response.statusCode = 200
        response.write(JSON.stringify(data))
        response.end()
    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/wcid foobar", (envelope, response) =>
          [nonce, timestamp, signatureHeader] = response.split("~")
          # trim Signature
          signatureItems = signatureHeader.split(" ", 2)[1]
          signatureItems = signatureItems.split(",")
          signatureKeys = {}
          for kv in signatureItems
            [key, value] = kv.split("=", 2)
            signatureKeys[key] = value

          base64Regex = /^[A-Za-z0-9+/]+=$/
          assert nonce.match(base64Regex), "#{nonce} did not match #{base64Regex}"
          assert ((Math.abs(Date.parse(timestamp) - new Date())) < 3000), "Duration from now to when timestamp was created should be very short"
          body = '{"user":"TestUser1","params":{"app":"foobar"},"room_id":"#TestRoom","method":"wcid"}'
          signatureString = "#{@chatopsUrl}/wcid\n#{nonce}\n#{timestamp}\n#{body}"

          verify = crypto.createVerify('RSA-SHA256')
          verify.write(signatureString)
          verify.end()
          publicKey = process.env.RPC_PUBLIC_KEY
          assert verify.verify(publicKey, signatureKeys.signature, 'base64'), "RSA signature did not match"
          done()


  it 'supports custom server error response messages', (done) ->
    error = null
    chatopListing =
          namespace: "deploy"
          help: "generic help about deployments\ntwo lines of it"
          error_response: "More information is perhaps available [in haystack](https://example.com)"
          methods:
            wcid:
              help: "where you can deploy?"
              regex: "(?:where can i deploy|wcid)(?: (?<app>\\S+))?",
              params: ["app", "generic_argument", "argument2"]
              path: "wcid"
            parse_error:
              help: "where you you parse error"
              regex: "this should be a parse error"
              path: "parse_error"

    @server.on 'request', (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        response.statusCode = 500
        response.write("{}")
        response.end()
      else if request.url is "/_chatops/parse_error"
        response.statusCode = 500
        response.write("this isnt even JSON!")
        response.end()
    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 2 methods."
        helper.converse @robot, @user, "/wcid foobar", (envelope, response) =>
          assert.include response, "<@TestUser1>: More information is perhaps available [in haystack]"
          helper.converse @robot, @user, "/this should be a parse error", (envelope, response) =>
            assert.include response, "<@TestUser1>: More information is perhaps available [in haystack]"
            helper.converse @robot, @user, "", (envelope, response) =>
              throw new Error("An extra message was sent after the error notification.")
            done(error)

  it 'reports user error by the response text', (done) ->
    # by default, log messages end up in the test output. UGH
    @robot.logger.level = 'ERROR'
    error = null
    chatopListing = @chatopListing
    @server.on 'request', (request, response) ->
      if request.url is "/_chatops"
        response.write JSON.stringify(chatopListing)
        response.end()
      else if request.url is "/_chatops/wcid"
        response.statusCode = 400
        response.write(JSON.stringify({ error: { message: "This is the error message." }}))
        response.end()
    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/wcid foobar", (envelope, response) =>
          assert.include response, "This is the error message."
          helper.converse @robot, @user, "", (envelope, response) =>
            throw new Error("An extra message was sent after the error notification.")
          done(error)

  it 'explains whats going on', (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)
    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/rpc what happens for /wcid foobar", (envelope, response) =>
          data = '{"user":"TestUser1","params":{"app":"foobar"},"room_id":"TestRoom","method":"wcid"}'
          assert.include response, "I found a chatop matching that, (?:where can i deploy|wcid)(?: (?<app>\\S+))?, from #{@chatopsUrl} (`.deploy`).\nI'm posting this JSON to #{@chatopsUrl}/wcid, using _:RPC_PRIVATE_KEY as authorization:\n#{data}"
          helper.converse @robot, @user, "/rpc what happens for absolutely nothing", (envelope, response) =>
            assert.include response, "That won't launch any chatops (but it might launch a regular hubot script, github/shell command, nuclear missile, or land invasion of russia in winter)."
            done(error)

  it "sets a server's prefix", (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/rpc set prefix #{@chatopsUrl} staging", (envelope, response) =>
          assert.include response, "Okay, I'll use 'staging' as a prefix for #{@chatopsUrl}"
          helper.converse @robot, @user, "/rpc list", (envelope, response) =>
            assert.include response, "Endpoint - Updated - Last response\n#{@chatopsUrl} (prefix: staging)"
            helper.converse @robot, @user, "/staging wcid", (envelope, response) =>
              assert.include response, "foo response!"
              helper.converse @robot, @user, "/wcid", (envelope, response) =>
                error = new Error "Unprefixed message should not have been received"
              process.nextTick ->
                # give it a tick so the /rpc wcid will match if it's going to
                done(error)

  it 'adds a server with a prefix', (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl} --prefix dat-prefix", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/rpc list", (envelope, response) =>
          assert.include response, "Endpoint - Updated - Last response\n#{@chatopsUrl} (prefix: dat-prefix)"
          helper.converse @robot, @user, "/dat-prefix wcid", (envelope, response) =>
            assert.include response, "foo response!"
            helper.converse @robot, @user, "/rpc add https://example.dev/_chatops --prefix dat-prefix", (envelope, response) =>
              assert.include response, "Sorry, dat-prefix is already associated with #{@chatopsUrl}"
              helper.converse @robot, @user, "/rpc remove #{@chatopsUrl}", (envelope, response) =>
                assert.include response, "I'll no longer poll or run commands from #{@chatopsUrl}"
                helper.converse @robot, @user, "/rpc add https://example.dev/_chatops --prefix dat-prefix", (envelope, response) =>
                  assert.include response, "Okay, I'll poll https://example.dev/_chatops for chatops."
                  done(error)

  it 'adds a v2 server with a prefix', (done) ->
    error = null
    chatopListing = @chatopListing
    chatopListing.version = "2"
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl} --prefix dat-prefix", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/rpc list", (envelope, response) =>
          assert.include response, "Endpoint - Updated - Last response\n#{@chatopsUrl} (prefix: dat-prefix)"
          helper.converse @robot, @user, "/dat-prefix wcid", (envelope, response) =>
            assert.include response, "foo response!"
            helper.converse @robot, @user, "/wcid", (envelope, response) =>
              error = new Error "Unprefixed message should not have been received"
            process.nextTick ->
              # give it a tick so the /rpc wcid will match if it's going to
              done(error)

  it 'fails to add a v2 server without a prefix', (done) ->
    error = null
    chatopListing = @chatopListing
    chatopListing.version = "2"
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl} claims to be chatops RPC version 2. Versions 2 and up require adding with a prefix, like .rpc add #{@chatopsUrl} --prefix <something>."
        done()

  it "adds a help listener at an endpoint's namespace or prefix", (done) ->
    error = null
    chatopListing = @chatopListing
    @server.on 'request', defaultServerResponder(chatopListing)

    helper.converse @robot, @user, "/rpc add #{@chatopsUrl}", (envelope, response) =>
      assert.include response, "Okay, I'll poll #{@chatopsUrl} for chatops."
      # This empty message makes the test helper fire the second message that's
      # fired asynchronously from the previous command.
      helper.converse @robot, @user, "", (envelope, response) =>
        assert.include response, "#{@chatopsUrl}: Found 1 method."
        helper.converse @robot, @user, "/deploy", (envelope, response) =>
          assert.include response, "generic help about deployments"
          helper.converse @robot, @user, "/rpc set prefix #{@chatopsUrl} staging", (envelope, response) =>
            assert.include response, "Okay, I'll use 'staging' as a prefix for #{@chatopsUrl}"
            helper.converse @robot, @user, "/staging", (envelope, response) =>
              assert.include response, "generic help about deployments"
              assert.include response, "hubot staging where can i deploy?"
              done(error)
