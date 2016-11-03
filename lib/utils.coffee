pad = (number) ->
  "0#{number}".slice(-2)

getStartOfDay = () ->
  date = new Date()
  year = date.getFullYear()
  paddedMonth = pad(date.getMonth() + 1)
  paddedDay = pad(date.getDate())
  new Date("#{year}-#{paddedMonth}-#{paddedDay}")

module.exports.getStartOfDay = getStartOfDay
