%%% The MIT License (MIT)
%%% Copyright (c) 2016 Hajime Nakagami<nakagami@gmail.com>

-module(efirebirdsql_server).

-behavior(gen_server).

-export([start_link/0, get_parameter/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([init/1, code_change/3, terminate/2]).

-include("efirebirdsql.hrl").

-record(state, {mod,
                sock,
                db_handle,
                trans_handle,
                stmt_handle,
                data = <<>>,
                parameters = [],
                types = [],
                columns = [],
                rows = [],
                results = []}).

attach_database(Sock, User, Password, Database) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_attach(User, Password, Database)),
    case efirebirdsql_op:get_response(Sock) of
        {op_response,  {ok, Handle, _}} -> {ok, Handle};
        _ -> {error, "Can't attach Database"}
    end.

create_database(Sock, User, Password, Database, PageSize) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_create(User, Password, Database, PageSize)),
    case efirebirdsql_op:get_response(Sock) of
        {op_response,  {ok, Handle, _}} -> {ok, Handle};
        _ -> {error, "Can't create database"}
    end.

begin_transaction(Sock, DbHandle, Tpb) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_transaction(DbHandle, Tpb)),
    case efirebirdsql_op:get_response(Sock) of
        {op_response,  {ok, Handle, _}} -> {ok, Handle};
        _ -> {error, "Can't begin transaction"}
    end.

allocate_statement(Sock, DbHandle) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_allocate_statement(DbHandle)),
    case efirebirdsql_op:get_response(Sock) of
        {op_response,  {ok, Handle, _}} -> {ok, Handle};
        _ -> {error, "Allocate statement failed"}
    end.

prepare_statement(Sock, TransHandle, StmtHandle, Sql) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_prepare_statement(TransHandle, StmtHandle, Sql)),
    efirebirdsql_op:get_prepare_statement_response(Sock, StmtHandle).

commit(Sock, TransHandle) ->
    gen_tcp:send(Sock,
        efirebirdsql_op:op_commit_retaining(TransHandle)),
    case efirebirdsql_op:get_response(Sock) of
        {op_response,  {ok, _, _}} -> ok;
        _ -> {error, "Commit failed"}
    end.

%% -- client interface --
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, list_to_binary(Name)}, infinity);
get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, Name}, infinity).

%% -- gen_server implementation --

init([]) ->
    {ok, #state{}}.

handle_call({connect, Host, Username, Password, Database, Options}, _From, State) ->
    SockOptions = [{active, false}, {packet, raw}, binary],
    Port = proplists:get_value(port, Options, 3050),
    IsCreateDB = proplists:get_value(createdb, Options, false),
    PageSize = proplists:get_value(pagesize, Options, 4096),
    case gen_tcp:connect(Host, Port, SockOptions) of
        {ok, Sock} ->
            gen_tcp:send(Sock,
                efirebirdsql_op:op_connect(Host, Username, Password, Database)),
            case efirebirdsql_op:get_response(Sock) of
                {op_accept, _} ->
                    case IsCreateDB of
                        true ->
                            R = create_database(
                                Sock, Username, Password, Database, PageSize);
                        false ->
                            R = attach_database(
                                Sock, Username, Password, Database)
                    end,
                    case R of
                        {ok, DbHandle} ->
                            case allocate_statement(Sock, DbHandle) of
                                {ok, StmtHandle} ->
                                    {reply, ok,
                                        State#state{sock = Sock,
                                        db_handle = DbHandle,
                                        stmt_handle = StmtHandle}};
                                {error, _Reason} ->
                                    {reply, {error, "Can't allocate statement"},
                                        State#state{sock = Sock,
                                            db_handle = DbHandle}}
                            end;
                        {error, _Reason} ->
                            {reply, R, State#state{sock = Sock}}
                    end;
                op_reject -> {reply, {error, "Connection Rejected"},
                                                State#state{sock = Sock}}
            end;
        Error = {error, _} -> {reply, Error, State}
    end;
handle_call({transaction, Options}, _From, State) ->
    AutoCommit = proplists:get_value(auto_commit, Options, true),
    %% isc_tpb_version3,isc_tpb_write,isc_tpb_wait,isc_tpb_read_committed,isc_tpb_no_rec_version
    Tpb = [3, 9, 6, 15, 18],
    R = begin_transaction(State#state.sock, State#state.db_handle,
        lists:flatten(Tpb, if AutoCommit =:= true -> [16]; true -> [] end)),
    case R of
        {ok, TransHandle} ->
            {reply, ok, State#state{trans_handle=TransHandle}};
        {error, _Reason} ->
            {reply, R, State}
    end;
handle_call(commit, _From, State) ->
    {reply, commit(State#state.sock, State#state.trans_handle), State};
handle_call(close, _From, State) ->
    %%% TODO: Do something
    {reply, ok, State};
handle_call({prepare, Sql}, _From, State) ->
    _Statement = prepare_statement(State#state.sock, State#state.trans_handle,
        State#state.stmt_handle, Sql);
handle_call({get_parameter, Name}, _From, State) ->
    Value1 = case lists:keysearch(Name, 1, State#state.parameters) of
        {value, {Name, Value}} -> Value;
        false                  -> undefined
    end,
    {reply, {ok, Value1}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_reply, _, ok}, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.