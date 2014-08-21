%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Copyright (c) 2012-2014 Kivra
%%%
%%% Permission to use, copy, modify, and/or distribute this software for any
%%% purpose with or without fee is hereby granted, provided that the above
%%% copyright notice and this permission notice appear in all copies.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
%%%
%%% @doc Erlang OAuth 2.0 implementation
%%%
%%%      This library is designed to simplify the implementation of the
%%%      server side of OAuth2 (http://tools.ietf.org/html/rfc6749).
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration ===============================================
-module(oauth2).
-compile({no_auto_import, [get/2]}).

%%%_* Exports ==========================================================
%%%_ * API -------------------------------------------------------------
-export([authorize_password/4]).
-export([authorize_password/6]).
-export([authorize_password/7]).
-export([authorize_resource_owner/3]).
-export([authorize_client_credentials/4]).
-export([authorize_code_grant/5]).
-export([authorize_code_request/6]).
-export([issue_code/2]).
-export([issue_token/2]).
-export([issue_token_and_refresh/2]).
-export([verify_access_token/2]).
-export([verify_access_code/2]).
-export([verify_access_code/3]).
-export([refresh_access_token/5]).

-export_type([token/0]).
-export_type([context/0]).
-export_type([auth/0]).
-export_type([lifetime/0]).
-export_type([scope/0]).
-export_type([appctx/0]).
-export_type([error/0]).

%%%_* Macros ===========================================================
-define(BACKEND, (oauth2_config:backend())).
-define(TOKEN,   (oauth2_config:token_generation())).

%%%_ * Types -----------------------------------------------------------
-record(a, { client   = undefined    :: undefined | term()
           , resowner = undefined    :: undefined | term()
           , scope                   :: scope()
           , ttl      = 0            :: non_neg_integer()
           }).

-type context()  :: proplists:proplist().
-type auth()     :: #a{}.
-type token()    :: binary().
-type response() :: oauth2_response:response().
-type lifetime() :: non_neg_integer().
-type scope()    :: list(binary()) | binary().
-type appctx()   :: term().
-type error()    :: access_denied | invalid_client | invalid_grant |
                    invalid_request | invalid_authorization | invalid_scope |
                    unauthorized_client | unsupported_response_type |
                    server_error | temporarily_unavailable.

%%%_* Code =============================================================
%%%_ * API -------------------------------------------------------------

%% @doc Validates a request for an access token from resource owner's
%%      credentials. Use it to implement the following steps of RFC 6749:
%%      - 4.3.2. Resource Owner Password Credentials Grant >
%%        Access Token Request, when the client is public.
-spec authorize_password(binary(), binary(), scope(), appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_password(UId, Pwd, Scope, AppCtx1) ->
    case ?BACKEND:authenticate_username_password(UId, Pwd, AppCtx1) of
        {error, _}                -> {error, access_denied};
        {ok, {AppCtx2, ResOwner}} ->
            case ?BACKEND:verify_resowner_scope(ResOwner, Scope, AppCtx2) of
                {error, _}              -> {error, invalid_scope};
                {ok, {AppCtx3, Scope2}} ->
                    {ok, { AppCtx3
                         , #a{
                               resowner = ResOwner
                             , scope    = Scope2
                             , ttl      = oauth2_config:expiry_time(
                                                password_credentials) } }}
            end
    end.

%% @doc Validates a request for an access token from client and resource
%%      owner's credentials. Use it to implement the following steps of
%%      RFC 6749:
%%      - 4.3.2. Resource Owner Password Credentials Grant >
%%        Access Token Request, when the client is confidential.
-spec authorize_password(binary(), binary(), binary(), binary(), scope(),
                         appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_password(CId, CSecret, UId, Pwd, Scope, AppCtx1) ->
    case ?BACKEND:authenticate_client(CId, CSecret, AppCtx1) of
        {error, _}              -> {error, invalid_client};
        {ok, {AppCtx2, Client}} ->
            case authorize_password(UId, Pwd, Scope, AppCtx2) of
                {error, _} = E        -> E;
                {ok, {AppCtx3, Auth}} -> {ok, {AppCtx3, Auth#a{client=Client}}}
            end
    end.

%% @doc Validates a request for an access token from client and resource
%%      owner's credentials. Use it to implement the following steps of
%%      RFC 6749:
%%      - 4.2.1. Implicit Grant > Authorization Request. when the client
%%      is public.
-spec authorize_password( binary(), binary(), binary(), binary(), binary()
                        , scope(), appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_password(CId, CSecret, RedirUri, UId, Pwd, Scope, AppCtx1) ->
    case ?BACKEND:authenticate_client(CId, CSecret, AppCtx1) of
        {error, _}              -> {error, invalid_client};
        {ok, {AppCtx2, Client}} ->
            case ?BACKEND:verify_redirection_uri(Client, RedirUri, AppCtx2) of
                {ok, AppCtx3} ->
                    case authorize_password(UId, Pwd, Scope, AppCtx3) of
                        {error, _} = E        -> E;
                        {ok, {AppCtx4, Auth}} -> {ok, {AppCtx4, Auth#a{client=Client}}}
                    end;
                _ -> {error, invalid_grant}
            end
    end.

%% @doc Authorizes a previously authenticated resource owner.  Useful
%%      for Resource Owner Password Credentials Grant and Implicit Grant.
-spec authorize_resource_owner(term(), scope(), appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_resource_owner(ResOwner, Scope, AppCtx1) ->
    case ?BACKEND:verify_resowner_scope(ResOwner, Scope, AppCtx1) of
        {error, _}              -> {error, invalid_scope};
        {ok, {AppCtx2, Scope2}} ->
            {ok, {AppCtx2 , #a{ resowner = ResOwner
                              , scope    = Scope2
                              , ttl      = oauth2_config:expiry_time(
                                                     password_credentials) } }}
    end.

%% @doc Validates a request for an access token from client's credentials.
%%      Use it to implement the following steps of RFC 6749:
%%      - 4.4.2. Client Credentials Grant > Access Token Request.
-spec authorize_client_credentials(binary(), binary(), scope(), appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_client_credentials(CId, CSecret, Scope, AppCtx1) ->
    case ?BACKEND:authenticate_client(CId, CSecret, AppCtx1) of
        {error, _}   -> {error, invalid_client};
        {ok, {AppCtx2, Client}} ->
            case ?BACKEND:verify_client_scope(Client, Scope, AppCtx2) of
                {error, _}   -> {error, invalid_scope};
                {ok, {AppCtx3, Scope2}} ->
                    {ok, {AppCtx3, #a{ client = Client
                                     , scope  = Scope2
                                     , ttl    = oauth2_config:expiry_time(
                                                       client_credentials) } }}
            end
    end.

%% @doc Validates a request for an access token from an authorization code.
%%      Use it to implement the following steps of RFC 6749:
%%      - 4.1.3. Authorization Code Grant > Access Token Request.
-spec authorize_code_grant(binary(), binary(), token(), binary(), appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_code_grant(CId, CSecret, Code, RedirUri, AppCtx1) ->
    case ?BACKEND:authenticate_client(CId, CSecret, AppCtx1) of
        {error, _}   -> {error, invalid_client};
        {ok, {AppCtx2, Client}} ->
            case ?BACKEND:verify_redirection_uri(Client, RedirUri, AppCtx2) of
                {ok, AppCtx3} ->
                    case verify_access_code(Code, Client, AppCtx3) of
                        {ok, {AppCtx4, GrantCtx}} ->
                            {ok, AppCtx5} = ?BACKEND:revoke_access_code(
                                                                Code
                                                              , AppCtx4),
                            {ok, { AppCtx5
                                 , #a{ client   = Client
                                     , resowner = get_( GrantCtx
                                                      , <<"resource_owner">> )
                                     , scope    = get_(GrantCtx, <<"scope">>)
                                     , ttl      =  oauth2_config:expiry_time(
                                                      password_credentials) }}};
                        Error ->
                            Error
                    end;
                _ -> {error, invalid_grant}
            end
    end.

%% @doc Validates a request for an authorization code from client and resource
%%      owner's credentials. Use it to implement the following steps of
%%      RFC 6749:
%%      - 4.1.1. Authorization Code Grant > Authorization Request.
-spec authorize_code_request( binary()
                            , binary()
                            , binary()
                            , binary()
                            , scope()
                            , appctx())
                            -> {ok, {appctx(), auth()}} | {error, error()}.
authorize_code_request(CId, RedirUri, UId, Pwd, Scope, AppCtx1) ->
    case ?BACKEND:get_client_identity(CId, AppCtx1) of
        {error, _}   -> {error, unauthorized_client};
        {ok, {AppCtx2, Client}} ->
            case ?BACKEND:verify_redirection_uri(Client, RedirUri, AppCtx2) of
                {ok, AppCtx3} ->
                    case ?BACKEND:authenticate_username_password(
                                   UId, Pwd, AppCtx3) of
                        {error, _}                -> {error, access_denied};
                        {ok, {AppCtx4, ResOwner}} ->
                            case ?BACKEND:verify_resowner_scope(
                                    ResOwner, Scope, AppCtx4) of
                                {error, _}              -> {error, invalid_scope};
                                {ok, {AppCtx5, Scope2}} ->
                                    TTL = oauth2_config:expiry_time(code_grant),
                                    {ok, {AppCtx5, #a{ client   = Client
                                                     , resowner = ResOwner
                                                     , scope    = Scope2
                                                     , ttl      = TTL
                                                     } }}
                            end
                    end;
                _ ->
                    {error, unauthorized_client}
            end
    end.

%% @doc Issues an authorization code from an authorization. Use it to implement
%%      the following steps of RFC 6749:
%%      - 4.1.2. Authorization Code Grant > Authorization Response, with the
%%        result of authorize_code_request/6.
-spec issue_code(auth(), appctx()) -> {ok, {appctx(), response()}}.
issue_code(#a{client = Client, resowner = ResOwner,
                           scope = Scope, ttl = TTL}, AppCtx1) ->
    ExpiryAbsolute = seconds_since_epoch(TTL),
    GrantContext   = build_context(Client, ExpiryAbsolute, ResOwner, Scope),
    AccessCode     = ?TOKEN:generate(GrantContext),
    {ok, AppCtx2}  = ?BACKEND:associate_access_code( AccessCode
                                                   , GrantContext
                                                   , AppCtx1) ,
    {ok, {AppCtx2, oauth2_response:new( <<>>
                                      , TTL
                                      , ResOwner
                                      , Scope
                                      , <<>>
                                      , AccessCode )}}.

%% @doc Issues an access token without refresh token from an authorization.
%%      Use it to implement the following steps of RFC 6749:
%%      - 4.1.4. Authorization Code Grant > Authorization Response, with the
%%        result of authorize_code_grant/5 when no refresh token must be issued.
%%      - 4.2.2. Implicit Grant > Access Token Response, with the result of
%%        authorize_password/7.
%%      - 4.3.3. Resource Owner Password Credentials Grant >
%%        Access Token Response, with the result of authorize_password/4 or
%%        authorize_password/6 when the client is public or no refresh token
%%        must be issued.
%%      - 4.4.3. Client Credentials Grant > Access Token Response, with the
%%        result of authorize_client_credentials/4.
-spec issue_token(auth(), appctx()) -> {ok, {appctx(), response()}}.
issue_token(#a{client = Client, resowner = ResOwner,
                           scope = Scope, ttl = TTL}, AppCtx1) ->
    ExpiryAbsolute = seconds_since_epoch(TTL),
    GrantContext   = build_context(Client, ExpiryAbsolute, ResOwner, Scope),
    AccessToken    = ?TOKEN:generate(GrantContext),
    {ok, AppCtx2}  = ?BACKEND:associate_access_token( AccessToken
                                                    , GrantContext
                                                    , AppCtx1 ),
    {ok, {AppCtx2, oauth2_response:new(AccessToken, TTL, ResOwner, Scope)}}.

%% @doc Issues access and refresh tokens from an authorization.
%%      Use it to implement the following steps of RFC 6749:
%%      - 4.1.4. Authorization Code Grant > Access Token Response, with the
%%        result of authorize_code_grant/5 when a refresh token must be issued.
%%      - 4.3.3. Resource Owner Password Credentials Grant >
%%        Access Token Response, with the result of authorize_password/6 when
%%        the client is confidential and a refresh token must be issued.
-spec issue_token_and_refresh(auth(), appctx())
                                           -> {ok, {appctx(), response()}} |
                                                {error, invalid_authorization}.
issue_token_and_refresh(#a{client = undefined}, _AppCtx1) ->
  {error, invalid_authorization};
issue_token_and_refresh(#a{resowner = undefined}, _AppCtx1) ->
  {error, invalid_authorization};
issue_token_and_refresh(#a{ client = Client
                          , resowner = ResOwner
                          , scope = Scope
                          , ttl = TTL}, AppCtx1) when ResOwner /= undefined ->
    ExpiryAbsolute = seconds_since_epoch(TTL),
    GrantContext   = build_context(Client, ExpiryAbsolute, ResOwner, Scope),
    AccessToken    = ?TOKEN:generate(GrantContext),
    RefreshToken   = ?TOKEN:generate(GrantContext),
    {ok, AppCtx2}  = ?BACKEND:associate_access_token( AccessToken
                                                    , GrantContext
                                                    , AppCtx1),
    {ok, AppCtx3}  = ?BACKEND:associate_refresh_token( RefreshToken
                                                     , GrantContext
                                                     , AppCtx2),
    {ok, { AppCtx3
         , oauth2_response:new(AccessToken, TTL, ResOwner, Scope, RefreshToken)}}.

%% @doc Verifies an access code AccessCode, returning its associated
%%      context if successful. Otherwise, an OAuth2 error code is returned.
-spec verify_access_code(token(), appctx())
                         -> {ok, {appctx(), context()}} | {error, error()}.
verify_access_code(AccessCode, AppCtx1) ->
    case ?BACKEND:resolve_access_code(AccessCode, AppCtx1) of
        {ok, {AppCtx2, GrantCtx}} ->
            case get_(GrantCtx, <<"expiry_time">>) > seconds_since_epoch(0) of
                true  -> {ok, {AppCtx2, GrantCtx}};
                false ->
                    ?BACKEND:revoke_access_code(AccessCode, AppCtx2),
                    {error, invalid_grant}
            end;
        _ -> {error, invalid_grant}
    end.

%% @doc Verifies an access code AccessCode and it's corresponding Identity,
%%      returning its associated context if successful. Otherwise, an OAuth2
%%      error code is returned.
-spec verify_access_code(token(), term(), appctx())
                         -> {ok, {appctx(), context()}} | {error, error()}.
verify_access_code(AccessCode, Client, AppCtx1) ->
    case verify_access_code(AccessCode, AppCtx1) of
        {ok, {AppCtx2, GrantCtx}} ->
            case get(GrantCtx, <<"client">>) of
                {ok, Client} -> {ok, {AppCtx2, GrantCtx}};
                _            -> {error, invalid_grant}
            end;
        Error -> Error
    end.

%% @doc Validates a request for an access token from a refresh token, issuing
%%      a new access token if valid. Use it to implement the following steps of
%%      RFC 6749:
%%      - 6. Refreshing an Access Token.
-spec refresh_access_token(binary(), binary(), token(), scope(), appctx())
                        -> {ok, {appctx(), response()}} | {error, error()}.
refresh_access_token(CId, CSecret, RefreshToken, Scope, AppCtx1) ->
    case ?BACKEND:authenticate_client(CId, CSecret, AppCtx1) of
        {ok, {AppCtx2, Client}} ->
            case ?BACKEND:resolve_refresh_token(RefreshToken, AppCtx2) of
                {ok, {AppCtx3, GrantCtx}} ->
                    {ok, ExpiryAbsolute} = get(GrantCtx, <<"expiry_time">>),
                    case ExpiryAbsolute > seconds_since_epoch(0) of
                        true ->
                            {ok, Client}   = get(GrantCtx, <<"client">>),
                            {ok, RegScope} = get(GrantCtx, <<"scope">>),
                            case ?BACKEND:verify_scope( RegScope
                                                      , Scope
                                                      , AppCtx3) of
                                {ok, {AppCtx4, VerScope}} ->
                                    {ok, ResOwner} = get( GrantCtx
                                                        , <<"resource_owner">> ),
                                    TTL = oauth2_config:expiry_time(
                                            password_credentials),
                                    issue_token(#a{ client   = Client
                                                  , resowner = ResOwner
                                                  , scope    = VerScope
                                                  , ttl      = TTL
                                                  }, AppCtx4);
                                {error, _Reason} -> {error, invalid_scope}
                            end;
                        false ->
                            ?BACKEND:revoke_refresh_token(RefreshToken,
                                                          AppCtx3),
                            {error, invalid_grant}
                    end;
                _ -> {error, invalid_grant}
            end;
        _ -> {error, invalid_client}
    end.

%% @doc Verifies an access token AccessToken, returning its associated
%%      context if successful. Otherwise, an OAuth2 error code is returned.
-spec verify_access_token(token(), appctx())
                         -> {ok, {appctx(), context()}} | {error, error()}.
verify_access_token(AccessToken, AppCtx1) ->
    case ?BACKEND:resolve_access_token(AccessToken, AppCtx1) of
        {ok, {AppCtx2, GrantCtx}} ->
            case get_(GrantCtx, <<"expiry_time">>) > seconds_since_epoch(0) of
                true  -> {ok, {AppCtx2, GrantCtx}};
                false ->
                    ?BACKEND:revoke_access_token(AccessToken, AppCtx2),
                    {error, access_denied}
            end;
        _ -> {error, access_denied}
    end.

%%%_* Private functions ================================================
-spec build_context(term(), non_neg_integer(), term(), scope()) -> context().
build_context(Client, ExpiryTime, ResOwner, Scope) ->
    [ {<<"client">>,         Client}
    , {<<"resource_owner">>, ResOwner}
    , {<<"expiry_time">>,    ExpiryTime}
    , {<<"scope">>,          Scope} ].

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
    {Mega, Secs, _} = os:timestamp(),
    Mega * 1000000 + Secs + Diff.

get(O, K)  ->
    case lists:keyfind(K, 1, O) of
        {K, V} -> {ok, V};
        false  -> {error, notfound}
    end.

get_(O, K) ->
    case get(O, K) of
        {ok, V}           -> V;
        {error, notfound} -> throw(notfound)
    end.

%%%_* Tests ============================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 4
%%% End:
