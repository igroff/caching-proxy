Promise = require 'bluebird'
_       = require 'lodash'
log     = require 'simplog'

idGenerator = 0

class Context extends require('stream').Readable
  constructor: (req) ->
      [@url, @queryString] = req.url.split('?')
      log.debug "req.url: #{req.url} url: #{@url} qs: #{@queryString}"
      @method = req.method
      @headers = req.headers
      @rawHeaders = req.rawHeaders
      @httpVersion = req.httpVersion
      @requestBody = ""
      @request = req
      @socket = req.socket
      @cacheLockDescriptor = null
      @contextId = ++idGenerator
      @isDebugRequest = false
      super({})
      return unless @queryString
      # we set up our debug flag if it was requests, AND we clear it
      # from the querystring so that it doesn't influence our cache key
      if @queryString.indexOf('&debug=true') isnt -1
        @queryString = @queryString.replace(/&debug=true/g, '')
        @isDebugRequest = true
      else if @queryString.indexOf('debug=true') isnt -1
        @queryString = @queryString.replace(/debug=true/g, '')
        @isDebugRequest = true
        
  toString: => JSON.stringify(url: @url, method: @method, config: @config, body: @body)
  _read: (size) =>
    @.push(this.requestBody)
    @.push(null)

buildContext = (request, response) ->
  new Promise (resolve) ->
    baseContext = new Context(request)
    baseContext.request = request
    baseContext.response = response
    resolve(baseContext)

module.exports = buildContext
