extends RefCounted

const PARSE_ERROR := JSONRPC.PARSE_ERROR
const INVALID_REQUEST := JSONRPC.INVALID_REQUEST
const METHOD_NOT_FOUND := JSONRPC.METHOD_NOT_FOUND
const INVALID_PARAMS := JSONRPC.INVALID_PARAMS
const INTERNAL_ERROR := JSONRPC.INTERNAL_ERROR

const AUTHENTICATION_FAILED := -32001
const UNSUPPORTED_PROTOCOL := -32002
const UNKNOWN_HANDLE := -32004
## Unsupported native values and bounded resource limits share this wire code.
const RESOURCE_LIMIT := -32010
const IMAGE_UNAVAILABLE := -32020
const INPUT_CONFLICT := -32030

var code: int
var message: String


func _init(value: int, description: String) -> void:
	code = value
	message = description
