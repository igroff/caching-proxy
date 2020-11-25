log       = require 'simplog'
config    = require './config.coffee'
cache     = require './cache-redis.coffee'

stringify = JSON.stringify

handleAdminRequest = (context) ->
  command = context.adminCommand
  response = context.response
  log.debug "handling admin request url #{context.url}, command: #{command}"
  if command is 'delete'
    handleDeleteRequest(context.cacheKey, response)
  else if command is "get"
    cache.getCacheEntry(context.cacheKey)
    .then( (cachedEntry) -> response.end(cachedEntry) )
  else if command is "config"
    # just handing back the current config for whatever reason the caller
    # may have need of seeing it
    response.end(stringify({status: 'ok', config: config}))
  else if command is "target"
    response.end(stringify(context.targetConfig))
  else if command is "diagnostic"
    response.end(stringify(status: 'ok', message: 'ok'))
  else if command is 'saveTargetConfig'
    handleConfigSaveRequest(context.request, context.response)
  else if command is 'targetConfig' and context.request.method is 'POST'
    updateTargetConfig(context)
  else
    response.end(stringify(status: 'error', message: 'unknown request'))


updateTargetConfig = (context) ->
  targetConfigList = context.requestBody
  throw new Error "must have a request body to parse as target config" unless context.requestBody
  try
    config.setTargetConfig(targetConfigList)
    log.warn "updating target config with %s", targetConfigList
    return context.response.end stringify({status: "ok", targets: config.targets})
  catch e
    context.response.writeHead 500, {}
    responseMessage =
      status: "error"
      message: "error validating config data: " + e
    context.response.end stringify(responseMessage)
    return

# this handles a request to save our config, since it can be modified at runtime
# we may want to ( or not want to ) persist any changes to disk so we allow the
# user to decide by invoking this method
handleConfigSaveRequest = (response) ->
  config.saveTargetConfig()
  .then () -> res.end(stringify(status: 'ok'))
  .catch (e) ->
    log.error "error saving target configuration data\n%s", e
    response.end(stringify(status: 'error', message: e.message))

# this handles a request to delete a cache entry
handleDeleteRequest = (cacheKey, response) ->
  cache.deleteCacheEntry(cacheKey)
  .then () ->
    response.end(stringify(status: 'ok', message: 'cache entry removed'))
  .catch (e) ->
    log.error "error removing cache entry\n%s", e
    response.end(stringify(status: 'error', message: e.message))

# 'admin requests', or those destined for the proxy server itself, will be prefixed in such a way
# as to make them ulikely to conflict with valid requests this method determines if we have
# an admin request and returns the admin command and the 'cleaned up' version of the url if the
# request is an admin request
getAdminRequestInfo = (request) ->
  return null unless request.url.startsWith('/____')
  trimmedUrl = request.url.replace(/^\/____\//, '')
  parts = trimmedUrl.split '/'
  command = parts.shift()
  url = "/#{parts.join('/')}"
  return [command, url]

module.exports.requestHandler = handleAdminRequest
module.exports.getAdminRequestInfo = getAdminRequestInfo
