%%%-------------------------------------------------------------------
%%% @author Heinz Nikolaus Gies <heinz@licenser.net>
%%% @copyright (C) 2013, Heinz Nikolaus Gies
%%% @doc
%%%
%%% @end
%%% Created : 30 Dec 2013 by Heinz Nikolaus Gies <heinz@licenser.net>
%%%-------------------------------------------------------------------
-module(fifo_s3_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->

    {ok, Pid} = supervisor:start_link({local, ?SERVER}, ?MODULE, []),

    %% setup rabbit connection pools
    %% we want these to be the first processes started, so the connections
    %% are available for all other processes
    RabbitConfig = common_util:get_rabbit_config(),
    lager:debug("Startin rabbit pools with sup config: ~p", [RabbitConfig]),
    F = fun({PoolName, ConfigProp}) ->
        %% Start a rabbit_pool_man process for each rabbit config entry
        PoolSupId = py_tools:make_child_spec_id(rabbit_pool_man, PoolName),
        Pool = {PoolSupId,
            {rabbit_pool_man, start_link, [[PoolName, ConfigProp]]},
            permanent, 2000, worker, [rabbit_pool_man]},
        {ok, _PoolPid} = supervisor:start_child(Pid, Pool),
        rabbit_pool_man:initialise(PoolName)

        end,
    lists:foreach(F, RabbitConfig),

    {ok, Pid}.
%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    {ok, USize} = application:get_env(fifo_s3, upload_pool_size),
    {ok, UMax} = application:get_env(fifo_s3, upload_pool_max),

    {ok, DSize} = application:get_env(fifo_s3, download_pool_size),
    {ok, DMax} = application:get_env(fifo_s3, download_pool_max),

    UploadPool = poolboy:child_spec(
                   s3_upload,
                   [{name, {local, s3_upload}},
                    {worker_module, fifo_s3_upload_worker},
                    {size, USize},
                    {max_overflow, UMax}],
                   []),
    DownloadPool = poolboy:child_spec(
                   s3_download,
                   [{name, {local, s3_download}},
                    {worker_module, fifo_s3_download_worker},
                    {size, DSize},
                    {max_overflow, DMax}],
                   []),
    {ok, {SupFlags, [UploadPool, DownloadPool,
                     ?CHILD(fifo_s3_upload_sup, supervisor),
                     ?CHILD(fifo_s3_download_sup, supervisor)
                     ]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
