functor
import
   AsyncExcept(raiseTo:RaiseTo unblocked:Unblocked safeThread:SafeThread)
   Util(concatMap:ConcatMap replicate:Replicate
	filterRecordsByLabel:FilterRecordsByLabel
	intercalate:Intercalate
	compareCaseInsensitive:CompareCaseInsensitive
	tupleLessThan:TupleLessThan) at 'x-ozlib://wmeyer/sawhorse/common/Util.ozf'
   Timeout(withTimeout:WithTimeout)
   Request(parseRequest:ParseRequest)
   Response(sendResponse:SendResponse
	    contentTypeHeader:ContentTypeHeader
	    lastModifiedHeader:LastModifiedHeader
	    okResponse:OkResponse
	    requestTimeOutResponse:RequestTimeOutResponse
	    notImplementedResponse:NotImplementedResponse
	    internalServerErrorResponse:InternalServerErrorResponse
	    notFoundResponse:NotFoundResponse
	    badRequestResponse:BadRequestResponse)
   at 'x-ozlib://wmeyer/sawhorse/common/Response.ozf'
   MimeTypes(init:InitMimeTypes mimeTypeOf:MimeTypeOf)
   Logging(newLogger:NewLogger newStream:NewStream)
   Plugin(loadPlugins shutDownPlugins find call)
   Query(parse)
   OS
   OsTime
   Open
   Module
   Property(put)
export
   Start
   Restart
   Kill
define
   proc {Restart S}
      {RaiseTo S restart}
   end

   proc {Kill S}
      {RaiseTo S kill}
   end

   %% Start the web server.
   %% Returns a handle which can be used to restart or kill the server.
   %% You can only start one server instance at the same time (within the same process).
   local
      L = {NewLock}
      R = {NewCell false}
   in
      fun {Start}
	 %% make sure we are not already running
	 lock L then
	    if @R then
	       raise server(alreadyStarted) end
	    else
	       %% run as a 'safe' thread: a thread that can be killed safely
	       R := true
	       Thread =
	       {SafeThread
		unit(run:proc {$} {StartServer Thread config} end
		     blocked:true
		     'finally':proc {$}
				  lock L then R:= false end
			       end
		    )}
	    in
	       Thread
	    end
	 end
      end
   end

   proc {StartServer Thread OldConfig}
      {Server Thread {ReadConfig OldConfig}}
   end

   fun {TryLink URI}
      [C] = {Module.link [URI]}
   in
      try
	 {Wait C}
	 just(C)
      catch _ then nothing
      end
   end
   
   local
      DefaultConfig = config(port:80
			     requestTimeout: 300
			     keepAliveTimeout: 15
			     acceptTimeOut:2*60*1000
			     documentRoot: "public_html"
			     directoryIndex: "index.html"
			     serverName: "localhost"
			     serverAlias: nil
			     typesConfig: "./mime.types"
			     defaultType:mimeType(text plain)
			     mimeTypes:mimeTypes
			     serverAdmin:"administrator@localhost"
			     logDir:"log"
			     accessLogFile:"http-access.log"
			     accessLogLevel:trace
			     errorLogFile:stdout
			     errorLogLevel:error
			     pluginDir:"x-ozlib://wmeyer/sawhorse/plugins"
			     plugins:unit
			    )
   in
      fun {ReadConfig OldConfig}
	 Config =
	 case {TryLink 'x-ozlib://wmeyer/sawhorse/server/Configuration.ozf'}
	 of nothing then DefaultConfig
	 [] just(C) then C.config
	 end
	 MimeTypes = try {InitMimeTypes Config.typesConfig}
		     catch E then {LogException E} mimeTypes
		     end
	 AccessStream = {NewStream init(Config.accessLogFile
					dir:Config.logDir)}
	 unit(trace:LogAccess ...) = {NewLogger init(module:"server"
						     stream:AccessStream
						     logLevel:Config.accessLogLevel)}
	 ErrorStream = {NewStream init(Config.errorLogFile
				       dir:Config.logDir)}
	 unit(error:LogError
	      debug:_
	      trace:Trace
	      t:_
	      exception:LogException
	     ) = {NewLogger init(module:"server" stream:ErrorStream logLevel:Config.errorLogLevel)}
      in
	 {AdjoinList Config [mimeTypes#MimeTypes
			     plugins#{Plugin.loadPlugins Config OldConfig}
			     logError#LogError
			     logException#LogException
			     logAccess#LogAccess
			     trace#Trace
			    ]}
      end
   end

   proc {Server Thread Config}
      {Config.trace server}
      try
	 {Unblocked Thread
	  proc {$}
	     ServerSocket = {New Open.socket
			     init(type:stream protocol:"tcp" time:Config.acceptTimeOut)}
	  in
	     try
		{ServerSocket bind(takePort:Config.port)}
		{ServerSocket listen}
		{AcceptConnections Config ServerSocket}
	     finally
		{ServerSocket close}
	     end
	  end
	 }
      catch restart then
	 %% log
	 {StartServer Thread Config}
      [] kill then
	 %% log
	 {Plugin.shutDownPlugins Config}
	 skip
      [] E then
	 try
	    {Config.logError E}
	 catch _ then skip end
	 {Server Thread Config}
      end
   end

   proc {AcceptConnections Config Socket}
      ClientSocket HostAddress
   in
      {Config.trace acceptConnections}
      {Socket accept(accepted:ClientSocket
		     acceptClass:class $ from Open.socket Open.text end
		     host:HostAddress
		     port:_)}
      case HostAddress of false then {Config.trace "accept time out"} skip
      else
	 thread
	    try
	       {Run Config firstRun ClientSocket HostAddress}
	    catch E then
	       {Config.logException E}
	    finally
	       try
		  {ClientSocket close}
	       catch _ then skip
	       end
	    end
	 end
      end
      {AcceptConnections Config Socket}
   end

   %% Deals with a specific connection.
   proc {Run Config Type ClientSocket HostAddress}
      {Config.trace run}
      TimeOutType =
      case Type of firstRun then requestTimeout [] consequentRun then keepAliveTimeout end
      TimeAllowed = 1000 * Config.TimeOutType
      Request =
      try
	 case {WithTimeout TimeAllowed fun {$} {GetFullRequest Config ClientSocket} end}
	 of timeout then
	    {Config.trace timeoutWaitingForRequest}
	    if Type == firstRun then
	       {SendResponse ClientSocket {RequestTimeOutResponse Config}}
	    end
	    nothing
	 [] R then just(R)
	 end
      catch
	 server(eofError(readLine)) then nothing
      [] E then
	 {Config.logException E}
	 nothing
      end
   in
      case Request of nothing then skip
      [] just(Req) then
	 {Config.trace "requestReceived: "#Req.1.cmd#", "#Req.1.originalURI}
	 {ProcessRequest Config Req ClientSocket HostAddress}
      end
   end

   proc {ProcessRequest Config Request ClientSocket HostAddress}
      case Request of
	 bad(RespCreator) then
	 %% log ?
	 {SendResponse ClientSocket {RespCreator Config}}
      [] ok(Req) then
	 Response = {HandleRequest Config Req}
      in
	 {SendResponse ClientSocket Response}
	 local
	    ConnectionHeaders = {ConcatMap
				 {FilterRecordsByLabel connection Req.headers}
				 fun {$ connection(Cs)} Cs end
				}
	    CloseConnection =
	    {Member close ConnectionHeaders}
	    orelse
	    {TupleLessThan Req.httpVersion 1#1}
	    andthen
	    {Not {Member keepAlive ConnectionHeaders}}
	 in
	    if {Not CloseConnection} then
	       {Run Config consequentRun ClientSocket HostAddress}
	    end
	 end
      end
   end

   fun {GetFullRequest Config ClientSocket}
      {Config.trace getFullRequest}
      Req = {GetRequest ClientSocket}
   in
      case {ParseRequest Config Req}
      of ok(Request) then
	 {Config.trace ok}
	 contentLength(Len) =
	 {CondSelect {FilterRecordsByLabel contentLength Request.headers}
	  1
	  contentLength(0)}
	 Body = {Replicate Len fun {$} {ClientSocket getC($)} end}
      in
	 ok({Adjoin request(body:Body) Request})
      [] R then {Config.trace notOk} R
      end
   end

   fun {GetRequest ClientSocket}
      {ReadStartLine ClientSocket}|{ReadUntilEmptyLine ClientSocket}
   end

   fun {ReadLine Text}
      case {Text getS($)}
      of false then raise server(eofError(readLine)) end
      [] L then {Filter L fun {$ C} C \= &\r end}
      end
   end
   
   fun {ReadStartLine ClientSocket}
      case {ReadLine ClientSocket}
      of nil then {ReadStartLine ClientSocket}
      [] Line then Line
      end
   end
   
   fun {ReadUntilEmptyLine ClientSocket}
      case {ReadLine ClientSocket}
      of nil then nil
      [] Line then Line|{ReadUntilEmptyLine ClientSocket}
      end
   end

   fun {HandleRequest Config Req=request(cmd:Cmd ...)}
      ErrorResponse
      Access = Cmd#": "#Req.originalURI
      Response
   in
      {Config.trace handleRequest}
      {Config.logAccess Access}
      Response =
      try
	 if {Not {CheckHostHeader Config Req ?ErrorResponse}} then ErrorResponse
	 else
	    case Cmd
	    of get then {HandleGetRequest Config Req withBody}
	    [] head then {HandleGetRequest Config Req withoutBody}
	    [] post then {HandlePostRequest Config Req unit}
	    else {NotImplementedResponse Config}
	    end
	 end
      catch E then
	 {Config.logException E}
	 {InternalServerErrorResponse Config}
      end
      {Config.logAccess "Response for "#Access#": "#Response.code}
      Response
   end

   fun {CheckHostHeader Config request(httpVersion:Ver headers:Headers ...) ?ErrorResponse}
      case {GetHost Headers}
      of nil andthen {TupleLessThan Ver 1#1} then true
      [] [Host] andthen (Host == Config.serverName
			 orelse {Member Host Config.serverAlias}) then true
      [] [H] then {Config.logError unknownHost#H}
	 ErrorResponse = {NotFoundResponse Config} false
      else ErrorResponse = {BadRequestResponse Config} false
      end
   end

   fun {GetHost Headers}
      {Map {FilterRecordsByLabel host Headers} fun {$ host(H _)} H end}
   end

   fun {EqualOrEmpty A B}
      A == unit orelse {CompareCaseInsensitive A B}
   end
   
   fun {MakeRequestHandler Fun}
      fun {$ Config Req=request(uri:URI ...) BodyFlag}
	 case URI of noURI then {BadRequestResponse Config}
	 else
	    if {Not {EqualOrEmpty URI.scheme "http"}}
	       orelse {Not {EqualOrEmpty URI.authority Config.serverName}}
	       orelse URI.fragment \= unit then
	       {NotFoundResponse Config}
	    else
	       {Fun Config Req BodyFlag}
	    end
	 end
      end
   end

   HandleGetRequest = {MakeRequestHandler
		       fun {$ Config Req=request(uri:URI headers:Hs ...) BodyFlag}
			  case {Plugin.find Config Req}
			  of nothing then
			     if Req.uri.query \= unit then {NotFoundResponse Config}
			     else {GetFile Config {MakeRelativePath URI.path} BodyFlag Hs}
			     end
			  [] just(P) then
			     Values = {Query.parse Req.uri.query}
			  in
			     {Plugin.call Config P handleGetRequest Req Values}
			  end
		       end
		      }
   HandlePostRequest = {MakeRequestHandler
			fun {$ Config Req _}
			   case {Plugin.find Config Req}
			   of nothing then {BadRequestResponse Config}
			   [] just(P) then
			      Values = {Query.parse Req.body}
			   in
			      {Plugin.call Config P handlePostRequest Req Values}
			   end
			end
		       }
  
   fun {MakeRelativePath Xs}
      &/|{Intercalate Xs "/"}
   end

   fun {GetFile Config Path BodyFlag Headers}
      case {FindRealFilename Config {PrependDocRoot Config Path}}
      of ErrorResp=response(...) then ErrorResp
      [] fileInfo(name:Filename stat:Status) then
	 {Config.trace realFilename#Filename}
	 {OkResponse Config
	  fileBody(Status.size Filename)
	  [{ContentTypeHeader {MimeTypeOf Config Filename}}
	   {LastModifiedHeader {OsTime.gmtime Status.mtime}}]
	  BodyFlag}
      end
   end

   fun {PrependDocRoot Config Path}
      case Path of &/|_ then {Append Config.documentRoot Path}
      else raise server(malformedPath(Path)) end
      end
   end

   fun {RemoveTrailingSlash Xs}
      case Xs
      of nil then nil
      [] [&/] then nil
      [] X|Xr then X|{RemoveTrailingSlash Xr}
      end
   end
   
   %% Returns either fileInfo(name:N stat:S) or, if the file is not found,
   %% an error response.
   fun {FindRealFilename Config Filename}
      FN = {RemoveTrailingSlash Filename}
      Status = {Stat FN}
   in
      {Config.trace Status}
      case Status of notFound then {NotFoundResponse Config}
      [] stat(type:dir ...) then
	 IndexFilename = {Append Filename &/|Config.directoryIndex}
	 S = {Stat IndexFilename}
      in
	 {Config.trace S}
	 case S of notFound then {NotFoundResponse Config}
	 [] stat(type:reg ...) then fileInfo(name:IndexFilename stat:S)
	 else raise server(findRealFilename(wrongIndexType(IndexFilename S))) end
	 end
      [] stat(type:reg ...) then
	 fileInfo(name:Filename stat:Status)
      else
	 {NotFoundResponse Config}
      end
   end
	     
   fun {Stat Filename}
      try
	 {OS.stat Filename}
      catch _ then notFound
      end
   end
end