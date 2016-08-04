_   = require 'lodash'
log = require 'simplog'

class Context extends require('stream').Readable
  constructor: (req) ->
      @url = req.url
      @queryString = req.url.split('?')[1]
      @method = req.method
      @headers = req.headers
      @rawHeaders = req.rawHeaders
      @httpVersion = req.httpVersion
      @requestBody = ""
      @request = req
      @socket = req.socket
      super({})
  toString: => JSON.stringify(url: @url, method: @method, config: @config, body: @body)
  _read: (size) =>
    @.push(this.requestBody)
    @.push(null)

buildContext = (request, response) ->
  new Promise (resolve) ->
    log.debug "buildContext"
    baseContext = new Context(request)
    baseContext.request = request
    baseContext.response = response
    baseContext.url = request.url
    resolve(baseContext)

module.exports = buildContext
