%% -------------------------------------------------------------------
%%
%% riak_kv_pb_index: Expose secondary index queries to Protocol Buffers
%%
%% Copyright (c) 2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc <p> Special service for riak cs. Fold over objects in buckets.
%% This covers the following request messages:</p>
%%
%% <pre>
%%  40 - RpbCSBucketReq
%% </pre>
%%
%% <p>This service produces the following responses:</p>
%%
%% <pre>
%%  41 - RpbCSBucketResp
%% </pre>
%% @end

-module(riak_kv_pb_csbucket).

-include_lib("../../riak_pb/include/riak_kv_pb.hrl"). %% @TODO reset this
-include("riak_kv_index.hrl").

-behaviour(riak_api_pb_service).

-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process_stream/3]).

-record(state, {client, req_id, req, continuation, result_count=0}).

%% @doc init/0 callback. Returns the service internal start
%% state.
-spec init() -> any().
init() ->
    {ok, C} = riak:local_client(),
    #state{client=C}.

%% @doc decode/2 callback. Decodes an incoming message.
decode(Code, Bin) ->
    {ok, riak_pb_codec:decode(Code, Bin)}.

%% @doc encode/1 callback. Encodes an outgoing response message.
encode(Message) ->
    {ok, riak_pb_codec:encode(Message)}.

process(Req=#rpbindexreq{}, State) ->
    #rpbcsbucketreq{bucket=Bucket, start_key=StartKey, start_incl=Incl,
                    continuation=Continuation, return_body=ReturnBody,
                    max_results=MaxResults} = Req,
    Query0 = riak_index:to_index_query(<<"$bucket">>, [Bucket], Continuation),
    Query = update_query(Query, ReturnBody, StartKey, Incl),
    maybe_perform_query(Query, Req, State).

update_query(?KV_INDEX_Q

maybe_perform_query({error, Reason}, _Req, State) ->
    {error, {format, Reason}, State};
maybe_perform_query({ok, Query}, Req, State) ->
    #rpbcsbucketreq{bucket=Bucket, max_results=MaxResults} = Req,
    #state{client=Client} = State,
    {ok, ReqId} = Client:stream_get_index(Bucket, Query, [{max_results, MaxResults}]),
    ReturnTerms = riak_index:return_terms(Req#rpbindexreq.return_terms, Query),
    {reply, {stream, ReqId}, State#state{req_id=ReqId, req=Req#rpbindexreq{return_terms=ReturnTerms}}}.

handle_query_results(_, _, {error, Reason}, State) ->
    {error, {format, Reason}, State};
handle_query_results(ReturnTerms, MaxResults,  {ok, Results}, State) ->
    Cont = make_continuation(MaxResults, Results, length(Results)),
    Resp = encode_results(ReturnTerms, Results, Cont),
    {reply, Resp, State}.

query_params(#rpbindexreq{qtype=eq, index=Index, key=Value, continuation=Continuation}) ->
    {Index, [Value], Continuation};
query_params(#rpbindexreq{index=Index, range_min=Min, range_max=Max, continuation=Continuation}) ->
    {Index, [Min, Max], Continuation}.

encode_results(true, Results0, Continuation) ->
    Results = [encode_result(Res) || Res <- Results0],
    #rpbindexresp{results=Results, continuation=Continuation};
encode_results(_, Results, Continuation) ->
    JustTheKeys = filter_values(Results),
    #rpbindexresp{keys=JustTheKeys, continuation=Continuation}.

encode_result({V, K}) when is_integer(V) ->
    V1 = list_to_binary(integer_to_list(V)),
    riak_pb_kv_codec:encode_index_pair({V1, K});
encode_result(Res) ->
    riak_pb_kv_codec:encode_index_pair(Res).

filter_values([]) ->
    [];
filter_values([{_, _} | _T]=Results) ->
    [K || {_V, K} <- Results];
filter_values(Results) ->
    Results.

make_continuation(MaxResults, Results, MaxResults) ->
    riak_index:make_continuation(Results);
make_continuation(_, _, _)  ->
    undefined.

%% @doc process_stream/3 callback. Handle streamed responses
process_stream({ReqId, done}, ReqId, State=#state{req_id=ReqId,
                                                  continuation=Continuation,
                                                  req=Req,
                                                  result_count=Count}) ->
    %% Only add the continuation if there (may) be more results to send
    #rpbindexreq{max_results=MaxResults} = Req,
    lager:info("XXXX YO!!! ~p ~p ~p", [is_integer(MaxResults), Count, MaxResults]),
    Resp = case is_integer(MaxResults) andalso Count =:= MaxResults of
               true -> #rpbindexresp{done=1, continuation=Continuation};
               false -> #rpbindexresp{done=1}
           end,
    {done, Resp, State};
process_stream({ReqId, {results, []}}, ReqId, State=#state{req_id=ReqId}) ->
    {ignore, State};
process_stream({ReqId, {results, Results}}, ReqId, State=#state{req_id=ReqId, req=Req, result_count=Count}) ->
    #rpbindexreq{return_terms=ReturnTerms, max_results=MaxResults} = Req,
    Count2 = length(Results) + Count,
    Continuation = make_continuation(MaxResults, Results, Count2),
    Response = encode_results(ReturnTerms, Results, undefined),
    {reply, Response, State#state{continuation=Continuation, result_count=Count2}};
process_stream({ReqId, Error}, ReqId, State=#state{req_id=ReqId}) ->
    {error, {format, Error}, State#state{req_id=undefined}};
process_stream(_,_,State) ->
    {ignore, State}.

