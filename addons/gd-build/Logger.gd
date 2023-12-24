extends Reference

enum LogLevel {
	ALL, DEBUG, INFO, WARN, ERROR, NONE
}
const DEFAULT_LOG_FORMAT_DETAIL = "[{time}] [{level}] {msg}"
const DEFAULT_LOG_FORMAT_NORMAL = "{msg}"

var log_level = LogLevel.INFO
var log_format = DEFAULT_LOG_FORMAT_NORMAL
var log_time_format = "{year}/{month}/{day} {hour}:{minute}:{second}"
var indent_level = 0
var is_locked = false


func debug(msg, raw=false):
	_log(LogLevel.DEBUG, msg, raw)

func info(msg, raw=false):
	_log(LogLevel.INFO, msg, raw)

func warn(msg, raw=false):
	_log(LogLevel.WARN, msg, raw)

func error(msg, raw=false):
	_log(LogLevel.ERROR, msg, raw)

func _log(level, msg, raw=false):
	if is_locked:
		return
	
	if typeof(msg) != TYPE_STRING:
		msg = str(msg)
	if log_level <= level:
		match level:
			LogLevel.WARN:
				push_warning(format_log(level, msg))
			LogLevel.ERROR:
				push_error(format_log(level, msg))
			_:
				if raw:
					printraw(format_log(level, msg))
				else:
					print(format_log(level, msg))

func format_log(level, msg):
	return log_format.format({
		"time": log_time_format.format(get_formatted_datatime()),
		"level": LogLevel.keys()[level],
		"msg": msg.indent("    ".repeat(indent_level))
	})

func indent():
	indent_level += 1

func dedent():
	indent_level -= 1
	max(indent_level, 0)

func lock():
	is_locked = true

func unlock():
	is_locked = false

func get_formatted_datatime():
	var datetime = OS.get_datetime()
	datetime.year = "%04d" % datetime.year
	datetime.month = "%02d" % datetime.month
	datetime.day = "%02d" % datetime.day
	datetime.hour = "%02d" % datetime.hour
	datetime.minute = "%02d" % datetime.minute
	datetime.second = "%02d" % datetime.second
	return datetime
