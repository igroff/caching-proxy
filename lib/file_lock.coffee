log = require 'simplog'

fs = require 'fs'
# 0x0080 O_SYNC
# 0x0020 O_EXLOCK
# 0x0400 O_TRUNC
# 0x0200 O_CREAT
# 0x0004 O_NONBLOCK
# 0x0002 F_WRITE
flags = 0x0080 | 0x0020 | 0x0400 | 0x0200 | 0x0004 | 0x0002

tryAquireLock = (lockFilePath) ->
  try
    fd = fs.openSync(lockFilePath, flags)
    # this is purely to help in any debugging that may be needed
    fs.writeSync(fd, new Date() + " - " + process.pid)
    log.debug "aquired lock for file #{lockFilePath}"
    return fd
  catch e
    # EAGAIN is raised if it's already locked which means
    # we couldn't aquire the lock
    if e.message.indexOf("EAGAIN") is -1
      log.error "error #{e.message} while trying to lock #{lockFilePath}"
    log.debug "unable to aquire lock for file #{lockFilePath}"
    return undefined

releaseLock = (lockFileDescriptor) ->
  try
    fs.closeSync(lockFileDescriptor)
    return true
  catch e
    # multiple attempts to release the lock can result in an error, but that's expected
    if e.message.indexOf('EBADF') is -1
      throw e
    return false
    

module.exports.releaseLock = releaseLock
module.exports.tryAquireLock = tryAquireLock
