-module(throwdown_arena).
-behaviour(gen_server).

-define(SERVER, ?MODULE).

-type arena_name() :: atom() | string() | binary().
-type arena_mode() :: 'waiting' | 'playing'.

-record(state, {
          name             :: arena_name(),
          mode             :: arena_mode(),
          rules            :: function(),
          player_count     :: pos_integer(),
          players = #{}    :: map(),
          game_state = #{} :: map()
}).


-export([
         start_link/1,
         start_link/2,
         child_spec/1,
         register_player/3,
         submit_choice/3,
         done/1,
         default_rules/2
        ]).

-export([
         init/1,
         handle_cast/2,
         handle_call/3,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% public API

start_link(Name) ->
    start_link(Name, fun default_rules/2).

start_link(Name, Rules) when is_function(Rules) ->
    gen_server:start_link(?MODULE, [Name, Rules], []).

child_spec(Name) ->
    #{id       => Name,
      start    => {throwdown_arena, start_link, []},
      restart  => temporary,
      shutdown => 2000,
      type     => worker,
      modules  => [throwdown_arena]}.

default_rules(rock, rock) -> tie;
default_rules(rock, paper) -> loss;
default_rules(rock, scissors) -> win;
default_rules(rock, lizard) -> win;
default_rules(rock, spock) -> loss;

default_rules(paper, paper) -> tie;
default_rules(paper, rock) -> win;
default_rules(paper, scissors) -> loss;
default_rules(paper, lizard) -> loss;
default_rules(paper, spock) -> win;

default_rules(scissors, scissors) -> tie;
default_rules(scissors, rock) -> loss;
default_rules(scissors, paper) -> win;
default_rules(scissors, lizard) -> win;
default_rules(scissors, spock) -> loss;

default_rules(lizard, lizard) -> tie;
default_rules(lizard, rock) -> loss;
default_rules(lizard, paper) -> win;
default_rules(lizard, scissors) -> loss;
default_rules(lizard, spock) -> win;

default_rules(spock, spock) -> tie;
default_rules(spock, rock) -> win;
default_rules(spock, paper) -> loss;
default_rules(spock, scissors) -> win;
default_rules(spock, lizard) -> loss.

-spec register_player( Arena :: pid(),
                       Name :: binary(),
                       PlayerPid :: pid() ) -> ok.
register_player(Arena, Name, PlayerPid) ->
    gen_server:call(Arena, {register, Name, PlayerPid}).

submit_choice(Arena, Name, Pick) ->
    gen_server:call(Arena, {choice, {Name, Pick}}).

done(Arena) ->
    gen_server:call(Arena, done).

%% gen_server callback

init([Name, Rules]) ->
    Choices = throwdown:get_env(choices, [rock, paper, scissors, lizard, spock]),
    GState = #{ choices => Choices, current => ordsets:new(), results => [] },
    {ok, #state{ name = Name, rules = Rules, game_state = GState }}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_call(done, _From, State) ->
    {reply, ok, State#state{mode = playing}};
handle_call({choice, _C}, _From, State = #state{ mode = waiting }) ->
    {reply, {error, cannot_select}, State};
handle_call({choice, C}, _From, State = #state{ mode = playing, players = P, game_state = G }) ->
    Current = maps:get(current, G),
    NewCurrent = ordset:add_element(C, Current),
    NewG = maps:put(current, NewCurrent, G),
    case ordset:size(NewCurrent) == maps:size(P) of
        true -> ?SERVER ! start_round;
        false -> ok
    end,
    {reply, ok, State#state{ game_state = NewG }};

handle_call({register, _Name, _PlayerPid}, _From, State = #state{ mode = playing }) ->
    {reply, {error, cannot_register}, State};
handle_call({register, Name, PlayerPid}, _From, State = #state{ mode = waiting,
                                                                players = P }) ->
    NewP = maps:put(Name, PlayerPid, P),
    {reply, ok, State#state{ players = NewP }};

handle_call(_Call, _From, State) ->
    {reply, dieeeeee, State}.

handle_info(start_round, State = #state{ rules = R, players = P, game_state = G }) ->
    Current = ordsets:to_list(maps:get(current, G)),
    Results = evaluate_choices(R, Current, Current, []),
    G1 = maps:put(current, ordsets:new(), G),
    R0 = maps:get(results, G),
    NewG = maps:put(results, [ Current | R0 ], G1),
    NewP = notify_results(Results, P),
    {noreply, State#state{ players = NewP, game_state = NewG }};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% private

notify_results([], P) -> P;
notify_results([ {loss, {Name, _Pick}} = R | Tail], P) ->
    Pid = maps:get(Name, P),
    throwdown_player:result(Pid, R),
    notify_results(Tail, maps:remove(Name, P));
notify_results([ {_, {Name, _}} = R | T ], P) ->
    Pid = maps:get(Name, P),
    throwdown_player:result(Pid, R),
    notify_results(T, P).

evaluate_choices(_Rules, [], _Picks, Acc) -> Acc;
evaluate_choices(Rules, [ H | Rest ], All, Acc) ->
    Picks = All - [H],
    Outcome = case versus(Rules, H, Picks, undefined) of
        tie -> {tie, H};
        win -> {win, H};
        loss -> {loss, H}
    end,
    evaluate_choices(Rules, Rest, All, [ Outcome | Acc ]).

versus(_Rules, _Player, [], Result) -> Result;
versus(Rules, {_NameA, PlayA} = A, [ {_NameB, PlayB} | T ], _LastResult) ->
    case Rules(PlayA, PlayB) of
        loss ->
            loss;
        Result ->
            versus(Rules, A, T, Result)
    end.

-ifdef(TEST).

-endif.
