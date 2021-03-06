%%%-------------------------------------------------------------------
%%% @author Sergey Sobko <ssobko@rbc.ru>
%%% @copyright (C) 2014, RosBusinessConsulting
%%% @doc
%%% Main logic for sessionserver.
%%% @end
%%% Created : 15.10.2014 15:53
%%%-------------------------------------------------------------------

-module(sessionserver).
-author("ssobko").

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([dispatch/1]).

%% Server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%% Definitions
-include_lib("sessionserver/include/sessionserver.hrl").
-define(SERVER, ?MODULE).


%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, [], []).

dispatch(Packet) ->
    Message = gen_server:call(?SERVER, {packet, Packet}),
    gen_server:call(?SERVER, {dispatch, Message}).

%% ===================================================================
%% Server callbacks
%% ===================================================================

init([]) ->
    {ok, []}.

handle_call({packet, Packet}, _From, State) ->
    Message = case sessionserver_lexer:string(Packet) of
        {ok, Tokens, _EndLine} ->
            sessionserver_parser:parse(Tokens);
        Others ->
            Others
    end,
    {reply, Message, State};

handle_call({dispatch, {ok, Statement}}, _From, State) ->
    Reply = execute_statement(Statement),
    {reply, Reply, State};

handle_call({dispatch, Message}, _From, State) ->
    {error, _Reason} = case Message of
        {error, ErrorTerm, _ErrorLine} ->
            {error, ErrorTerm};
        {error, ErrorTerm} ->
            {error, ErrorTerm}
    end,
    Reply = {close, get_string({error, unknown})},
    {reply, Reply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal functions
%% ===================================================================

%% String representation
-spec get_string(term()) -> string().
get_string({ok, {create, Password, Session, Groups, Login}}) ->
    "OK All ok" ++ ?CRLF ++
    "password=" ++ atom_to_list(Password) ++  ?CRLF ++
    "session_id=" ++ atom_to_list(Session) ++  ?CRLF ++
    "groups=" ++ Groups ++  ?CRLF ++
    "login=" ++ atom_to_list(Login);

get_string({ok, {delete, Session, Login}}) ->
    "OK All ok" ++  ?CRLF ++
    "session_id=" ++ atom_to_list(Session) ++ ?CRLF ++
    "login=" ++ atom_to_list(Login);

get_string({error, {create_login, Login}}) ->
    "ERROR No user with login '" ++ atom_to_list(Login) ++ "'";

get_string({error, create_password}) ->
    "ERROR Invalid password";

get_string({error, check}) ->
    "ERROR No such session";

get_string({error, unknown}) ->
    "ERROR Unknown command";

get_string({error, something_wrong}) ->
    "ERROR Something gone wrong".

-spec get_string_reply(User :: term(), Login :: atom()) -> string().
get_string_reply(User, Login) ->
    case User of
        {ok, {GotLogin, GotPassword, Groups, Session}} ->
            get_string({ok, {
                create,
                GotPassword,
                Session,
                string:join(lists:map(fun erlang:atom_to_list/1, Groups), " "),
                GotLogin
            }});
        {error, invalid_password} ->
            get_string({error, create_password});
        {error, invalid_login} ->
            get_string({error, {create_login, Login}});
        {error, invalid_session} ->
            get_string({error, check});
        _Others ->
            get_string({error, something_wrong})
    end.

%% Use database backend to handle client input
-spec execute_statement(term()) -> {skip, ok} | {close, string()} | {message, string()}.
execute_statement({version, _Version}) ->
    {skip, ok};

execute_statement({create, Login, Password}) ->
    User = case sessionserver_db:check_user(Login, Password) of
        {ok, {Login, Password, Groups, OldSession}} ->
            NewSession = case OldSession of
                null ->
                    sessionserver_session:get_new_session();
                OldSession ->
                    OldSession
            end,
            sessionserver_db:update_user(Login, Password, Groups, NewSession),
            {ok, {Login, Password, Groups, NewSession}};
        Others ->
            Others
    end,
    Reply = get_string_reply(User, Login),
    {close, Reply};

execute_statement({delete, Session}) ->
    Reply = case sessionserver_db:check_session(Session) of
        {ok, {Login, Password, Groups, Session}} ->
            sessionserver_db:update_user(Login, Password, Groups, null),
            get_string({ok, {delete, Session, Login}});
        {error, Error} ->
            get_string_reply({error, Error}, login)
    end,
    {close, Reply};

execute_statement({check, Session}) ->
    User = sessionserver_db:check_session(Session),
    Reply = get_string_reply(User, login),
    {close, Reply}.
