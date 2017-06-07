# Description:
#  Poll chatops endpoints from remote systems to expose their operations
#
# Commands:
#   hubot rpc list - list servers we're polling
#   hubot rpc add <server> - add a server to the poll list
#   hubot rpc delete <server> - remove a server from the poll list
#   hubot rpc debug <server> - Show what hubot saw when he last polled this URL
#   hubot rpc hup - requery all RPC chatops servers
#   hubot rpc wtf <command> - Explain how hubot will run an RPC command
#   hubot rpc raw namespace.command --arg1 foo --arg2 bar - Run a command if you can't be bothered to match a regex

_ = require('underscore')
namedRegexp = require("named-js-regexp")
timeAgo = require("time-ago")()
crypto = require 'crypto'


DEFAULT_FETCH_INTERVAL = 10 * 1000  # 10 seconds
MAX_FETCH_INTERVAL = 60 * 60 * 1000 # 1 hour
REGEXP_METACHARACTERS = /[-[\]{}()*+?.,\\^$|#\s]/g
GENERIC_ARGUMENT_MATCHER_SOURCE = "(?: --(?:.+))"

module.exports = (robot) ->
  get_room_name = (robot, room_id) =>
    return room_id

  if robot.adapterName is 'slack'
    {get_room_name} = require('./room-helper')

  privateKey = process.env.RPC_PRIVATE_KEY
  unless privateKey?
    robot.logger.error "The RPC_PRIVATE_KEY environment variable is not set; RPC commands are unknown."
    return

  robot.assignedChatopsRpcUrlPrefixes = (url) ->
    robot.brain.data.rpc_endpoint_prefixes[url]

  robot.assignChatopsRpcUrlPrefix = (url, prefix) ->
    robot.brain.data.rpc_endpoint_prefixes[url] = prefix

  robot.urlForChatopsRpcPrefix = (prefix) ->
    existing_url = _.find Object.keys(robot.brain.data.rpc_endpoint_prefixes), (key) ->
      robot.assignedChatopsRpcUrlPrefixes(key) == prefix
    return existing_url

  robot.clearChatopsRpcPrefixForUrl = (url) ->
    delete robot.brain.data.rpc_endpoint_prefixes[url]

  # Generate the nonce, timestamp, and signature for the given request body.
  authHeaders = (url, body) ->
    nonce = crypto.randomBytes(32).toString('base64')
    timestamp = new Date().toISOString()
    body ||= ""
    signatureString = "#{url}\n#{nonce}\n#{timestamp}\n#{body}"
    signature = crypto.createSign('RSA-SHA256').update(signatureString).sign(privateKey, 'base64')
    signatureHeader = "Signature keyid=hubotkey,signature=#{signature}"
    { nonce: nonce, timestamp: timestamp, signature: signatureHeader }

  # Extract trailing `--foo bar baz bum` arguments from a string.
  #
  # Returns a tuple of [text_with_args_removed, { foo: "bar baz bum" }]
  #
  # Example:
  #   ".ci build foo --arg1 has some spaces --bool"
  #   [".ci build foo", { arg1: "has some spaces", bool: "true" }]
  extractGenericArguments = (text) ->
    args = {}
    lastIndex = text.lastIndexOf(" --")
    while lastIndex != -1
      argument = text.slice(lastIndex)
      spaceIndex = argument.indexOf(" ", 1)
      key = val = null
      argument.slice(3, spaceIndex)
      if spaceIndex == -1
        val = "true"
        key = argument.slice(3)
      else
        val = argument.slice(spaceIndex + 1)
        key = argument.slice(3, spaceIndex)
      args[key] = val
      text = text.substring(0, lastIndex)
      lastIndex = text.lastIndexOf(" --")
    return [text, args]

  rejectListenersFromUrl = (url) ->
    # TODO: this should be in hubot core; diving into the implementation here
    listenersToKeep = _.reject robot.listeners, (listener) ->
      result = (listener.options.origin == url)
      if result
        robot.logger.debug "Removing listener #{listener.options.id} due to updating all listeners from #{url}"
        if listener.options.help?
          existingHelpCommandIndex = robot.commands.indexOf(listener.options.help)
          if existingHelpCommandIndex != -1
            robot.commands.splice(existingHelpCommandIndex, 1)
      else
        robot.logger.debug "Keeping listener with options #{listener.options.origin} and #{listener.options.id}"
      result
    robot.listeners = listenersToKeep

  # Anchor source to beginning and end of regex, prefix with 'hubot|/'
  createSourceRegex = (source, hubotPrefix, commandPrefix) ->
    if source.indexOf("^") == 0
      source = source.slice(1)
    if source.lastIndexOf("$") == source.length - 1
      source = source.slice(0, source.length - 1)
    if commandPrefix?
      commandPrefix = "#{commandPrefix} "
    else
      commandPrefix = ""
    source = "^#{hubotPrefix}#{commandPrefix}#{source}"

    source += GENERIC_ARGUMENT_MATCHER_SOURCE + "*"

    source += "$"
    return namedRegexp(source, "i")

  addHelpListener = (url, responseData, hubotPrefix) ->
    endpointPrefix = robot.assignedChatopsRpcUrlPrefixes(url)
    helpTrigger = endpointPrefix || responseData.namespace
    regex = createSourceRegex(helpTrigger, hubotPrefix, undefined)

    metadata =
      id: "#{responseData.namespace}.main-help"
      origin: url

    matcher = (message) ->
      regex.execGroups(message.text)?

    helpLines = for name, method of responseData.methods
      method.help
    helpOutput = responseData.help + "\n" + helpLines.join("\n")
    responder = (response) ->
      response.send helpOutput
      response.finish()

    robot.listen matcher, metadata, responder

  addListener = (url, endpoint, name, opts, hubotPrefix) ->
    commandPrefix = robot.assignedChatopsRpcUrlPrefixes(url)
    robot.logger.debug("Registering RPC endpoint named '#{name}' with prefix #{commandPrefix}")
    regex = createSourceRegex(opts.regex, hubotPrefix, commandPrefix)
    namespace = endpoint.namespace
    error_response = endpoint.error_response

    if opts.help?
      # Hubot core will strip out leading 'hubot ' from help and replace it
      # with the correct whatever.
      helpPrefix = if commandPrefix? then "#{commandPrefix} " else ""
      opts.help = "hubot " + helpPrefix + opts.help
    metadata =
      id: "#{namespace}.#{name}"
      namespace: namespace
      method: name
      origin: url
      help: if opts.help? then opts.help else ''
      source_regex: opts.regex

    methodUrl = if opts.path? then url + "/" + opts.path else url
    matcher = (message) ->
      regex.execGroups(message.text)?

    responder = (response) ->
      response.finish()

      user = response.message.user.name
      room_id = "#" + get_room_name(robot, response.message.user.room)
      data = responder.extractData(response.message.text, room_id, user)
      responder.executeAction(response, data)

    responder.executeAction = (response, data) ->
      data.method = name

      json = JSON.stringify(data)
      headers = authHeaders(responder.methodUrl, json)
      robot.logger.debug "Sending RPC request to an endpoint named #{name}."
      robot.http(responder.methodUrl).
            header("Chatops-Nonce", headers.nonce).
            header("Chatops-Timestamp", headers.timestamp).
            header("Chatops-Signature", headers.signature).
            timeout(150 * 1000).
            header("Content-type","application/json").
            header("Accept","application/json").
            post(JSON.stringify(data)) (err, res, body) ->
        if err
          robot.emit 'error', err, response
          sendRpcError(response, err.toString(), error_response)
          return
        robot.logger.debug "RPC response status=#{res.statusCode}"
        parsed = null
        try
          parsed = JSON.parse(body)
        catch error
          sendRpcError(response, body, error_response)
          return
        if parsed == null
          # body was null
          message = "Invalid output, null"
          sendRpcError(response, message, error_response)
        else if parsed.error and parsed.error.message
          robot.logger.warning "RPC error message=#{parsed.error.message}"
          # Was an error, just show the message
          sendMessage(response, parsed.error.message)
        else if parsed.title or parsed.image_url
          # Looks like a rich reponse message
          sendRichMessage(response, parsed)
        else if typeof parsed.result is "undefined"
          message = "Invalid response, missing result (HTTP code: #{res.statusCode})"
          sendRpcError(response, message, error_response)
        else if parsed.result?
          # A plain message, with content, just send it
          sendMessage(response, parsed.result)
        else
          # A plain message, no content, say no output
          message = "`#{response.message.text}` returned no output"
          sendMessage(response, message)

    responder.extractData = (text, room_id, user) ->
      [text, args] = extractGenericArguments(text)
      params = regex.execGroups(text)
      _.extend params, args
      data = { user: user, params: params, room_id: room_id }
    responder.methodUrl = methodUrl

    robot.commands.push metadata.help
    robot.listen matcher, metadata, responder

  sendRpcError = (response, error, error_response) ->
    sliced = error.slice(0, 300)
    robot.logger.error "Error in RPC request: #{sliced}"
    if error_response?
      response.send "<@#{response.message.user.name}>: #{error_response}"
    else
      response.send "Error: #{sliced}"

  sendMessage = (response, message) ->
    # Not sure how to test this. our framework only supports testing responses,
    # how do we test that no response is sent?
    return if message.replace(/\s/g, "") == ""
    if robot.adapterName is 'slack' and message.length > 7980
      robot.logger.debug "sendMessage: slack snippet"
      # this is challenging to test because its adapter-specific. Alas.
      channel = get_room_name(robot, response.envelope.room)
      robot.postSnippet channel, message, (result) ->
        unless result.ok
          response.send "Couldn't post a snippet of that long message: #{JSON.stringify(result)}"
    else
      robot.logger.debug "sendMessage: plain"
      response.send message

  sendRichMessage = (response, parsed) ->
    # For now we only support rich results with image_urls
    if robot.adapterName is 'slack' and parsed.image_url
      robot.logger.debug "sendRichMessage: slack.attachment"
      msgData =
        text: ""
        attachments: [
          {
            fallback: parsed.image_url
            title: parsed.title
            title_link: parsed.title_link
            color: parsed.color
            image_url: parsed.image_url
            text: ""
          }
        ]
      response.send msgData
    else
      robot.logger.debug "sendRichMessage: failback to plain"
      sendMessage(parsed.result)

  addListeners = (url, rpcResponseData) ->
    robot.brain.data.rpc_endpoints[url] = rpcResponseData
    rejectListenersFromUrl(url)

    # TODO: hubot respondPattern wants to make a regex object, which is
    # invalid because we're using an external library to parse regexes with
    # named groups. Ideally, hubot would provide us just access to the 'string'
    # portion of the prefix command and not create a RegExp, as named groups
    # will cause a compilation error in node.
    # Accordingly, these regexes and the prefixes below are stolen from
    # robot.coffee in hubot, but used slightly differently.
    regexEscapedRobotName = robot.name.replace(REGEXP_METACHARACTERS, '\\$&')
    alias = if robot.alias then robot.alias.replace(REGEXP_METACHARACTERS, '\\$&') else null

    hubotPrefix = if alias?
      "[@]?(?:#{regexEscapedRobotName}[:,]?|#{alias}[:,]?):?\\s*"
    else
      "[@]?(?:#{regexEscapedRobotName}[:,]?):?\\s*"

    namespace = rpcResponseData.namespace
    for name, opts of rpcResponseData.methods
      addListener(url, rpcResponseData, name, opts, hubotPrefix)
    addHelpListener(url, rpcResponseData, hubotPrefix)

  shortBodyMessage = (response, body) ->
    response.statusCode + ": " + body.replace(/\n/g, '\\n').slice(0, 150)

  # Fetch a particular URL's RPC endpoints and store them in the brain.
  # Runs a callback when it's done with a boolean argument of 'true' for
  # success and 'false' for failure.
  fetchRpc = (url, cb) ->
    headers = authHeaders(url)
    robot.http(url).
      header("Chatops-Nonce", headers.nonce).
      header("Chatops-Timestamp", headers.timestamp).
      header("Chatops-Signature", headers.signature).
      header("Accept", "application/json").
      get() (err, response, body) ->
        endpoint = robot.brain.data.rpc_endpoints[url]
        return cb?(false) unless endpoint? # this endpoint was deleted. it will go away completely the next time hubot restarts.
        if err || response.statusCode != 200
          if err
            robot.logger.debug "Got an error fetching RPC endpoints from #{url}: #{err}"
            endpoint.last_response = err
            endpoint.updated_at = new Date()
          else
            # We're replacing newlines here with literal \n's to display in chat.
            # if this is HTML it gets noisy quick
            robot.logger.debug "Got an error fetching RPC endpoints from #{url}: #{shortBodyMessage(response, body)}"
            endpoint.last_response = shortBodyMessage(response, body)
            endpoint.updated_at = new Date()
          return cb?(false)
        try
          data = JSON.parse(body)

          if data.version? && !robot.assignedChatopsRpcUrlPrefixes(url)?
            endpoint.last_response = "#{url} claims to be chatops RPC version 2. Versions 2 and up require adding with a prefix, like .rpc add #{url} --prefix <something>."
            return cb?(false)

          addListeners(url, data)
          # endpoints will have been replaced
          endpoint = robot.brain.data.rpc_endpoints[url]

          length = Object.keys(data.methods).length
          noun = if length == 1 then "method" else "methods"
          endpoint.last_response = "Found #{length} #{noun}."
          endpoint.updated_at = new Date()
          return cb?(true)
        catch e
          endpoint.last_response = shortBodyMessage(response, body)
          endpoint.updated_at = new Date()
          return cb?(false)

  setFetchRpcBackoff = (url, timeout) ->
    setTimeout ->
      fetchRpc url, (success) ->
        if success
          setFetchRpcBackoff url, DEFAULT_FETCH_INTERVAL
        else
          setFetchRpcBackoff url, Math.min(timeout * 1.5, MAX_FETCH_INTERVAL)
    , timeout

  fetchAllRpc = ->
    for url, endpoint of robot.brain.data.rpc_endpoints
      fetchRpc url
      setFetchRpcBackoff url, DEFAULT_FETCH_INTERVAL

  statusForUrl = (url) ->
    endpoint = robot.brain.data.rpc_endpoints[url]
    ago = if endpoint.updated_at? then timeAgo.ago(endpoint.updated_at) else "never"
    if robot.assignedChatopsRpcUrlPrefixes(url)?
      result = "#{url} (prefix: #{robot.assignedChatopsRpcUrlPrefixes(url)})"
    else
      result = url
    "#{result} - #{ago} - #{endpoint.last_response}"

  robot.brain.data.rpc_endpoints ||= {}
  robot.brain.data.rpc_endpoint_prefixes ||= {}
  fetchAllRpc()

  robot.respond /rpc list/, id: "rpc.list", (response) ->
    endpoints = robot.brain.data.rpc_endpoints
    rows = ["Endpoint - Updated - Last response"]
    for url, endpoint of endpoints
      rows.push(statusForUrl(url))
    response.send rows.join "\n"

  robot.respond /rpc debug (\S+)/, id: "rpc.debug", (response) ->
    url = response.match[1]
    message = JSON.stringify robot.brain.data.rpc_endpoints[url], null, 2
    response.reply "Info for #{url}:"
    response.send message

  robot.respond /rpc set prefix (\S+) (.*)/, id: "rpc.setprefix", (response) ->
    url = response.match[1]
    prefix = response.match[2]
    if robot.brain.data.rpc_endpoints[url]?
      if robot.urlForChatopsRpcPrefix(prefix)?
        return response.reply("Sorry, #{prefix} is already associated with #{robot.urlForChatopsRpcPrefix(prefix)}")
      robot.assignChatopsRpcUrlPrefix(url, prefix)
      fetchRpc url, ->
        response.send "Okay, I'll use '#{prefix}' as a prefix for #{url}"
    else
      response.send "I'm not querying #{url} for chatops. Try #{robot.alias}rpc add #{url} to add it."

  robot.respond new RegExp("rpc add (\\S+)(#{GENERIC_ARGUMENT_MATCHER_SOURCE})*?"), id: "rpc.add", (response) ->
    url = response.match[1]
    [unused, args] = extractGenericArguments(response.message.text)
    prefix = args.prefix
    unless url.indexOf("https") == 0 or robot.adapterName == 'mock-adapter'
      response.reply("Sorry, RPC ChatOps is HTTPS-only")
      return
    if prefix? and robot.urlForChatopsRpcPrefix(prefix)?
      return response.reply("Sorry, #{prefix} is already associated with #{robot.urlForChatopsRpcPrefix(prefix)}")
    response.reply("Okay, I'll poll #{url} for chatops.")
    robot.brain.data.rpc_endpoints[url] = {}
    robot.assignChatopsRpcUrlPrefix(url, prefix) if prefix?
    fetchRpc url, ->
      response.send "#{url}: " + robot.brain.data.rpc_endpoints[url].last_response
    setFetchRpcBackoff url, DEFAULT_FETCH_INTERVAL

  robot.respond /rpc delete (\S+)/, id: "rpc.delete", (response) ->
    url = response.match[1]

    if robot.brain.data.rpc_endpoints[url]
      delete(robot.brain.data.rpc_endpoints[url])
      robot.clearChatopsRpcPrefixForUrl(url)
      response.reply("I'll no longer poll or run commands from #{url}")
      rejectListenersFromUrl(url)
    else
      response.reply("I didn't know about #{url} anyway.")

  robot.respond /rpc (?:wtf|what happens for) (.*)/, id: "rpc.wtf", (response) ->
    text = response.match[1]
    listener = _.find robot.listeners, (listener) ->
      # Only select for RPC chatops.
      return false unless listener.options.source_regex?
      listener.matcher({text: text})

    if listener?
      room = get_room_name(robot, response.message.user.room)
      data = listener.callback.extractData(text, room, response.message.user.name)
      data.method = listener.options.method
      data = JSON.stringify(data)
      response.send "I found a chatop matching that, #{listener.options.source_regex}, from #{listener.options.origin} (`.#{listener.options.namespace}`).\nI'm posting this JSON to #{listener.callback.methodUrl}, using _:RPC_PRIVATE_KEY as authorization:\n#{data}"
    else
      response.send "That won't launch any chatops (but it might launch a regular hubot script, github/shell command, nuclear missile, or land invasion of russia in winter)."

  rawRegex = "rpc raw ([^\\s\\.]+\\.[^\\s\\.]+)(#{GENERIC_ARGUMENT_MATCHER_SOURCE})*"
  robot.respond new RegExp(rawRegex), id: "rpc.raw", (response) ->
    id = response.match[1]
    method = response.match[2]
    [unused, args] = extractGenericArguments(response.message.text)
    responder = _.find robot.listeners, (listener) ->
      listener.options.id == id
    if responder?
      data = {}
      data.user = response.message.user.name
      data.room_id = "#" + get_room_name(robot, response.message.user.room)
      data.params = args

      responder.callback.executeAction(response, data)
    else
      response.reply "I couldn't find a method called #{id}"

  robot.respond /rpc (hup|reload)/i, id: "rpc.hup", (response) ->
    for url, endpoint of robot.brain.data.rpc_endpoints
      fetchRpc url
    response.send "Okay, I'm re-fetching all RPC endpoints for updates."
