log       = require 'simplog'
config    = require './config.coffee'
cache     = require './cache.coffee'

jdumps    = JSON.stringify

handleAdminRequest = (context) ->
  command = context.adminCommand
  response = context.response
  log.debug "handling admin request url #{context.url}, command: #{command}"
  if command is 'delete'
    handleDeleteRequest(context.cacheKey, response)
  else if command is "config"
    # just handing back the current config for whatever reason the caller
    # may have need of seeing it
    response.end(jdumps({status: 'ok', config: config}))
  else if command is "target"
    # regexp is purely for our own internal matching, no need to return it
    response.end(jdumps(context.targetConfig))
  else if command is "diagnostic"
    response.end(jdumps(status: 'ok', message: 'ok'))
  else if command is 'saveTargetConfig'
    handleConfigSaveRequest(context.request, context.response)
  else if command is 'targetConfig' and context.request.method is 'POST'
    updateTargetConfig(context)
  else
    response.end(jdumps(status: 'error', message: 'unknown request'))


updateTargetConfig = (context) ->
  targetConfigList = context.requestBody
  throw new Error "must have a request body to parse as target config" unless context.requestBody
  try
    targetConfigList = JSON.parse(targetConfigList)
  catch e
    context.response.writeHead 500, {}
    responseMessage =
      status: "error"
      message: "error parsing config data: " + e
    context.response.end JSON.stringify(responseMessage)
    return
  try
    config.setTargetConfig(targetConfigList)
    log.warn "updating target config with %j", targetConfigList
  catch e
    context.response.writeHead 500, {}
    responseMessage =
      status: "error"
      message: "error validating config data: " + e
    context.response.end JSON.stringify(responseMessage)
    return
  context.response.writeHead 200, {}
  context.response.end JSON.stringify({status: "ok", targets: config.targets})

# this handles a request to save our config, since it can be modified at runtime
# we may want to ( or not want to ) persist any changes to disk so we allow the
# user to decide by invoking this method
handleConfigSaveRequest = (response) ->
  config.saveTargetConfig()
  .then () -> res.end(jdumps(status: 'ok'))
  .catch (e) ->
    log.error "error saving target configuration data\n%s", e
    response.end(jdumps(status: 'error', message: e.message))

# this handles a request to delete a cache entry
handleDeleteRequest = (cacheKey, response) ->
  cache.deleteCacheEntry(cacheKey)
  .then () ->
    response.end(jdumps(status: 'ok', message: 'cache entry removed'))
  .catch (e) ->
    log.error "error removing cache entry\n%s", e
    response.end(jdumps(status: 'error', message: e.message))

# because we want to allow requests to go to the proxy it's self we need a way to allow 
# requests that target the proxy to be identified, these so called 'admin' requests
# will be prefixed with an unreasonable number of forward slashes '/' to lessen the liklihood
# of a conflict with legitemate proxied requests.
#
# Because of the way the proxy code works with both callbacks and global ( response ) events being
# part of the process of handling a proxied request, some of our state is most easily passed around
# via decorating request, as such we will add proprties to the request indicating that the inbound
# request is an admin request, and then we'll remove the admin 'stuff' from the request url so that
# the normal request info can be processed.  This is because admin requests to do things like delete
# cache entries come in as prefix data on the url, for example
# http://proxy_server_host////delete/this/item.html
# is a request to the proxy server ( an admin request ) for it to delete the cached item /this/item.html
# so the portion /this/item.html is a 'legitimate' url, and the ////delete is just decoration to 
# indicate that the request is an 'admin' request, and that deletion is the desired action
getAdminRequestInfo = (request) ->
  # admin requests will start with ////
  return null unless request.url.startsWith('////')
  trimmedUrl = request.url.replace(/^\/\/\/\//, '')
  parts = trimmedUrl.split '/'
  command = parts.shift()
  url = "/#{parts.join('/')}"
  return [command, url]

module.exports.requestHandler = handleAdminRequest
module.exports.getAdminRequestInfo = getAdminRequestInfo
