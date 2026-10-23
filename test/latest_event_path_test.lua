-- Production-function harness; native player/socket boundaries are supplied by fixtures.
bit32={bxor=function(a,b) return (a ~ b)&0xFFFFFFFF end,band=function(a,b) return (a & b)&0xFFFFFFFF end}
local function read(path) local f=assert(io.open(path));local s=f:read('*a');f:close();return s end
local source=read('main/src/network.lua')
local queue=assert(source:match('(local function queue_reliable_udp_event.-)\nlocal function queue_reliable_udp_result'))
local dispatch=assert(source:match('(function M.on_udp_datagram.-)\nfunction M.ensure_tcp_server'))
local env=setmetatable({M={},SERVER_EVENT_ID_MAX=0x7FFFFFFF,unpack_values=table.unpack},{__index=_G})
env.udp_events=require('main.src.udp_events');env.event_codec=require('main.src.event_codec')
env.log={warn=function(...) error(string.format(...)) end}
local connection={is_open=true}
local client={hello=true,bound=true,pending_events={},pending_results={}}
local state={clients={[connection]=client},next_event_id=1,config={maxEventBytes=262144},tick=0}
local queue_event=assert(load(queue..'\nreturn queue_reliable_udp_event','production queue','t',env))()
local hash=assert(env.udp_events.hash_event_name('camera'))
local args=assert(env.event_codec.encode_args(1,2,3))
assert(queue_event(state,connection,'camera',hash,args,true))
assert(next(client.pending_events)==nil and next(client.pending_results)==nil)
assert(queue_event(state,connection,'camera',hash,args,true))
local r=require('main.src.reliable_udp');r.advance(client.udp_reliable,0,true);r.next(client.udp_reliable)
local receiver=r.new();local deliveries=r.receive(receiver,assert(r.next(client.udp_reliable)))
assert(#deliveries==1 and deliveries[1].latest and deliveries[1].id==2)
assert(not r.next(receiver) and #r.take_receipts(receiver)==0)
assert(queue_event(state,connection,'normal',hash,args,false))
assert(client.pending_events[3] and next(client.pending_results)==nil)
local calls=0;local authorized=true
env.validate_bound_player=function(c,p) assert(c==connection and p==client);return authorized end
env.handle_client_event=function(s,c,m) assert(s==state and c==connection and m.latest);calls=calls+1 end
env.udp_events.accept=function() error('Unexpected receipt') end
env.queue_reliable_udp_result=function() error('Unexpected processing result') end
assert(load(dispatch,'production dispatch','t',env))()
env.M.on_udp_datagram(state,{connection=connection,client=client,messages={{kind=1,latest=true}}})
assert(calls==1 and next(client.pending_results)==nil)
authorized=false
env.M.on_udp_datagram(state,{connection=connection,client=client,messages={{kind=1,latest=true}}})
assert(calls==1,'Bound-player authorization still applies')
print('Latest server path: queue/dispatch, no results/receipts, replacement and authorization passed')
-- Exercise public wrappers and shared serializers from production source.
local core_source=read('../core/main/init.lua')
local core_emit=assert(core_source:match('(local function emit_server_event.-)\nfunction __src_dispatch_server_event'))
local core_codec=dofile('../core/main/eventCodec.lua')
local lane,wire
local function capture(expected)
    return function(name,event_hash,bytes) assert(name=='camera' and #event_hash==8);lane=expected;wire=bytes;return false end
end
local core_env=setmetatable({event_codec=core_codec,server_event_names_by_hash={},
    __src_emit_server_event=capture('reliable'),__src_emit_server_event_latest=capture('latest')},{__index=_G})
assert(load(core_emit,'core public API','t',core_env))()
assert(core_env.emitServerEventLatest('camera',42,nil,'pose')==false and lane=='latest')
local values=assert(core_codec.decodeArgs(wire));assert(values[1]==42 and values[2]==nil and values[3]=='pose' and values.n==3)
assert(core_env.emitServerEvent('camera',true)==false and lane=='reliable')
local api_source=read('main/src/init.lua')
local server_emit=assert(api_source:match('(local function emit_client_event.-)\nworld_mutations.install'))
local api_env=setmetatable({src={},state=state,event_codec=env.event_codec,network={emit_client_event=function(s,p,name,event_hash,bytes,latest)
    assert(s==state and p==nil and name=='camera' and #event_hash==8);wire=bytes;lane=latest and 'latest' or 'reliable';return 2
end}},{__index=_G})
assert(load(server_emit,'server public API','t',api_env))()
assert(api_env.src.emitClientEventLatest(nil,'camera',42,nil,'pose')==2 and lane=='latest')
local args=assert(env.event_codec.decode_args(wire));assert(args.n==3 and args[1]==42 and args[3]=='pose')
assert(api_env.src.emitClientEvent(nil,'camera',true)==2 and lane=='reliable')
assert(not pcall(api_env.src.emitClientEventLatest,{},'camera'),'Invalid player targets rejected')
assert(not pcall(core_env.emitServerEventLatest,'',1),'Empty event names rejected')
local core_meta=read('../core/.meta/template/globals.lua')
local server_meta=read('.meta/template/globals.lua')
assert(core_meta:find('function emitServerEventLatest(name, ...) end',1,true))
assert(core_meta:find('function __src_emit_server_event_latest(eventName, eventHash, argsBytes) end',1,true))
assert(server_meta:find('function src.emitClientEventLatest(player, name, ...) end',1,true))
print('Latest public APIs: serializers, nil arguments, returns, lanes, invalid inputs and metadata passed')
