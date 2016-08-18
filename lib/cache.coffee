Promise       = require 'bluebird'
fs            = Promise.promisifyAll(require('fs'))
path          = require 'path'
log           = require 'simplog'
EventEmitter  = require 'events'

config  = require './config.coffee'

# just a counter to help us create unique file names
tempCounter = 0
cacheEventEmitter = new EventEmitter()
lockMap = {}
# an arbitrary, but larger than default, max listener count
# It really shouldn't ever be hit but I kind of feel like we want to know if we
# have a shitload of cache waiters backed up and this 'll blow it up so we
# can see
cacheEventEmitter.setMaxListeners(1000)

tryGetCachedResponse = (cacheKey) ->
  log.debug "tryGetCachedResponse(#{cacheKey})"
  [cacheFilePath, cacheBodyFilePath] = getCacheFilePath cacheKey
  return fs.statAsync(cacheFilePath)
  .then () ->
    fs.statAsync(cacheBodyFilePath)
  .then (stats) ->
    log.debug "cacheFilePath #{cacheFilePath}"
    log.debug "cacheBodyFilePath #{cacheBodyFilePath}"
    Promise.all([fs.readFileAsync(cacheFilePath, encoding: 'utf8'), stats])
  .then (r) ->
    data = r[0]
    stats = r[1]
    log.debug "cacheFileData: #{data}"
    lines = data.split('\n')
    cacheResponse = {}
    cacheResponse.statusCode = Number(lines[0])
    cacheResponse.statusMessage = lines[1]
    cacheResponse.headers = JSON.parse(lines[2])
    cacheResponse.createTime = stats.ctime.getTime()
    cacheResponse.body = fs.createReadStream(cacheBodyFilePath)
    return cacheResponse
  .catch (e) ->
    log.debug "error opening cache file #{cacheFilePath} #{e.message}"
    return undefined

getCacheFilePath = (requestInfo) ->
  uniqueIdentifier = "#{process.pid}.#{new Date().getTime()}.#{++tempCounter}"
  cacheFilePath = path.join(config.cacheDir, requestInfo)
  cacheFileTempPath = path.join(config.tempDir, "#{requestInfo}.#{uniqueIdentifier}")
  return [cacheFilePath, "#{cacheFilePath}.body", cacheFileTempPath, "#{cacheFileTempPath}.body"]

deleteCacheEntry = (cacheKey) ->
  [cacheFilePath] = getCacheFilePath cacheKey
  log.debug "deleting cache file #{cacheFilePath}"
  fs.unlinkAsync(cacheFilePath)
  .catch( (e) ->
    # it's cool if we get asked to delete a chache entry that isn't there but if we get
    # anything else, we want it to bubble up
    if e.message.indexOf("ENOENT") is -1
      throw e
  )

cacheResponse = (cacheKey, response) ->
  new Promise (resolve, reject) ->
    [cacheFilePath, cacheBodyFilePath, cacheFileTempPath, cacheBodyFileTempPath] = getCacheFilePath cacheKey
    log.debug "caching response metadata to #{cacheFilePath}, and body to #{cacheBodyFilePath}"
    metadataStream = fs.createWriteStream(cacheFileTempPath, {flag: 'w', defaultEncoding: 'utf8'})
    promiseForMetadataFileToEndWrite = new Promise (resolve, reject) ->
      metadataStream.on 'finish', resolve
      metadataStream.on 'error', reject
    metadataStream.write("#{response.statusCode}\n")
    metadataStream.write("#{response.statusMessage}\n")
    metadataStream.write("#{JSON.stringify response.headers}\n")
    metadataStream.end()
    bodyCacheWriteStream = fs.createWriteStream(cacheBodyFileTempPath, {flat: 'w', defaultEncoding: 'utf8'})
    response.pipe(bodyCacheWriteStream)
    promiseForResponseToEnd = new Promise (resolve, reject) ->
      bodyCacheWriteStream.on 'finish', resolve
      bodyCacheWriteStream.on 'error', reject
      response.on 'error', reject
    # once the response is complete, we will have written (piped) out the response to the
    # temp file, all that remains is to move the temp files into place of the 'non temp' 
    # files
    promiseForMetadataFileToEndWrite
    .then () -> promiseForResponseToEnd
    .then () -> fs.renameAsync(cacheFileTempPath, cacheFilePath)
    .then () -> fs.renameAsync(cacheBodyFileTempPath, cacheBodyFilePath)
    .tap log.debug "response for #{cacheKey} has been written to cache"
    .then () -> cacheEventEmitter.emit("#{cacheKey}")
    .then resolve
    .catch( (e) ->
      cacheEventEmitter.emit "#{cacheKey}", e
      reject(e)
    )

promiseToGetCacheLock = (cacheKey) ->
  return new Promise (resolve, reject) ->
    resolve(null) if lockMap[cacheKey]
    lockMap[cacheKey] =  true
    resolve(cacheKey)

promiseToReleaseCacheLock = (lockDescriptor) ->
  new Promise (resolve, reject) ->
    delete lockMap[lockDescriptor]
    resolve()

module.exports.tryGetCachedResponse = tryGetCachedResponse
module.exports.cacheResponse = cacheResponse
module.exports.promiseToGetCacheLock = promiseToGetCacheLock
module.exports.promiseToReleaseCacheLock = promiseToReleaseCacheLock
module.exports.deleteCacheEntry = deleteCacheEntry
module.exports.events = cacheEventEmitter
