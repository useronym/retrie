-module(retrie).

-export([new/0, insert_pattern/3, insert_compiled/3, lookup_match/2]).

-type tree() :: tree_node() | tree_chain().
-type tree_node() :: {value(), array2:array2(), patterns()}.
-type tree_chain() :: {key(), tree_node()}.
-type patterns() :: [{retrie_patterns:pattern(), tree()}].

-type key() :: unicode:unicode_binary().
-type value() :: term().


-spec new() -> tree().
new() ->
    {undefined, array2:new(), []}.


-spec insert_pattern(unicode:unicode_binary(), value(), tree()) -> tree().
insert_pattern(Binary, Value, Tree) ->
    insert_compiled(retrie_patterns:compile(Binary), Value, Tree).

-spec insert_compiled(retrie_patterns:patterns(), value(), tree()) -> tree().
insert_compiled([], Val, {Chain, {_, Array, Patterns}}) ->
    {Chain, {Val, Array, Patterns}};
insert_compiled([], Val, {_, Array, Patterns}) ->
    {Val, Array, Patterns};
insert_compiled([<<>> | Rest], Val, {<<LH, LT/bits>>, NextNode}) ->
    NewNode = {undefined, array2:set(LH, {LT, NextNode}, array2:new()), []},
    insert_compiled(Rest, Val, NewNode);
insert_compiled([Bin | Rest], Val, {Chain, NextNode}) when Bin == Chain ->
    {Chain, insert_compiled(Rest, Val, NextNode)};
insert_compiled([Bin | Rest], Val, {Chain, NextNode}) when is_binary(Bin) ->
    case binary:longest_common_prefix([Bin, Chain]) of
        P when (P == 0) or (P == 1) ->
            <<ChainH, ChainT/binary>> = Chain,
            NewNode = {undefined, array2:set(ChainH, {ChainT, NextNode}, array2:new()), []},
            insert_compiled([Bin | Rest], Val, NewNode);
        P when byte_size(Chain) == P ->
            {Chain, insert_compiled([binary:part(Bin, P, byte_size(Bin) - P) | Rest], Val, NextNode)};
        P ->
            <<Common:P/binary, RestChain/binary>> = Chain,
            NewNode = case RestChain of
                          <<RestH>> -> {undefined, array2:set(RestH, NextNode, array2:new()), []};
                          <<RestH, RestT/binary>> -> {undefined, array2:set(RestH, {RestT, NextNode}, array2:new()), []}
                      end,
            {Common, insert_compiled([binary:part(Bin, P, byte_size(Bin) - P) | Rest], Val, NewNode)}
    end;
insert_compiled([<<>> | Rest], Val, Node) ->
    insert_compiled(Rest, Val, Node);
insert_compiled([<<H, T/bits>> | Rest], Val, {NodeVal, Array, Patterns}) ->
    NewTree = case array2:get(H, Array) of
                  undefined when T == <<>> -> insert_compiled(Rest, Val, new());
                  undefined -> {T, insert_compiled(Rest, Val, new())};
                  Tree -> insert_compiled([T | Rest], Val, Tree)
              end,
    {NodeVal, array2:set(H, NewTree, Array), Patterns};
insert_compiled([Pattern | Rest], Val, {NodeVal, Array, Patterns}) ->
    NewPatterns = case lists:keytake(Pattern, 1, Patterns) of
                      false -> [{Pattern, insert_compiled(Rest, Val, new())} | Patterns];
                      {value, {_Pattern, Tree1}, Ps} -> [{Pattern, insert_compiled(Rest, Val, Tree1)} | Ps]
                  end,
    SortedPatterns = lists:sort(fun({P1, _}, {P2, _}) -> retrie_patterns:compare(P1, P2) end, NewPatterns),
    {NodeVal, Array, SortedPatterns}.


-spec lookup_match(key(), tree()) -> {value(), [{binary(), term()}]} | nomatch.
lookup_match(<<H, T/bits>> = In, {_, Array, Patterns}) ->
    case array2:get(H, Array) of
        undefined -> lookup_match_patterns(In, Patterns);
        Tree when Patterns == [] -> lookup_match(T, Tree);
        Tree ->
            case lookup_match(T, Tree) of
                nomatch -> lookup_match_patterns(In, Patterns);
                Res -> Res
            end
    end;
lookup_match(Input, {Chain, NextNode}) ->
    ChainLen = bit_size(Chain),
    case Input of
        <<Chain:ChainLen/bits, Rest/bits>> -> lookup_match(Rest, NextNode);
        _ -> nomatch
    end;
lookup_match(<<>>, {NodeVal, _, _}) when NodeVal /= undefined ->
    {NodeVal, []};
lookup_match(_, _) ->
    nomatch.

lookup_match_patterns(_, []) ->
    nomatch;
lookup_match_patterns(Input, [{Pattern, Tree} | RestPatterns]) ->
    case retrie_patterns:match(Input, Pattern) of
        {Match, Rest, Name} ->
            case lookup_match(Rest, Tree) of
                nomatch -> lookup_match_patterns(Input, RestPatterns);
                {Value, Matches} -> {Value, [{Name, retrie_patterns:convert(Match, Pattern)} | Matches]}
            end;
        _ -> lookup_match_patterns(Input, RestPatterns)
    end.

