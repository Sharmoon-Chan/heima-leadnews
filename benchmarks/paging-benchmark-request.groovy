import groovy.json.JsonSlurper
String requestBody=new String(Base64.decoder.decode(vars.get('body_base64')),'UTF-8')
def connection=(HttpURLConnection)new URL(vars.get('url')).openConnection()
connection.requestMethod='POST'
connection.connectTimeout=3000
connection.readTimeout=10000
connection.doOutput=true
connection.setRequestProperty('Content-Type','application/json; charset=utf-8')
connection.outputStream.withCloseable{it.write(requestBody.getBytes('UTF-8'))}
int code=connection.responseCode
String response=(code==200?connection.inputStream:connection.errorStream).getText('UTF-8')
def body=new JsonSlurper().parseText(response)
def items=body.data instanceof List?body.data:body.data?.items
def expected=vars.get('expected').split(';') as List
def actual=items?.collect{it.id.toString()}
boolean ok=code==200 && body.code==200 && actual==expected
vars.put('es_took',body.data instanceof Map?body.data.tookMs.toString():'')
vars.put('case_id',vars.get('case'))
SampleResult.setResponseCode(code.toString())
SampleResult.setResponseMessage(ok?'page identities match':'page identity/response mismatch')
SampleResult.setSuccessful(ok)
SampleResult.setResponseData(ok?'':response,'UTF-8')
connection.disconnect()
