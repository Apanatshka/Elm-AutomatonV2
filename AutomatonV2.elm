module AutomatonV2 where

{-| This library is a way to package up dynamic behavior. It makes it easier to
dynamically create dynamic components. It's based on the standard Elm Automaton
library, but requires GADTs, which are not supported yet...

# Create
@docs pure, state, hiddenState

# Evaluate
@docs run

# Extend and Combine
@docs extendDown, extendUp
@docs andThen, loop, pair, branch, combi, combine

# Common Automatons
@docs count, average
-}

import open Basics
import Signal (lift,foldp,Signal)
import open List
import Maybe (Just, Nothing)

data Automaton input output = Pure (input -> output)
                            | Stateful state (input -> state -> (output,state))

-- The basics

{-| Lift a normal function to the status of Automaton (which sounds far more awesome)
AFRP name: `arr`
-}
pure: (i -> o) -> Automaton i o
pure = Pure

{-| Connect two automatons. The first one gives it's output to the second one.
AFRP name: >>>
-}
andThen: Automaton i inter -> Automaton inter o -> Automaton i o
andThen first second =
  case first of
    Pure f -> case second of                               -- f  is the function from first
      Pure s       -> Pure (s . f)                         -- s  is the function from second
      Stateful b s -> Stateful b (\i -> s (f i))           -- b  is the base state from second
    Stateful fb f -> case second of                        -- fb is the base state from first
      Pure s        -> Stateful fb (\i st ->               -- sb is the base state from second
                        let (inter, st') = f i st          -- i  is the input
                        in (s inter, st'))                 -- st is the input state
      Stateful sb s -> Stateful (fb, sb) (\i (fst, sst) -> -- inter is the intermediate value
                        let (inter, fst') = f i fst        -- st' is the new state
                            (o, sst')     = s inter sst    -- fst and sst are the state of first and second
                        in (o, (fst', sst')))              -- ect...

{-| Add an extra input "channel" to be ignored and just sent on as output.
Mostly useful as a building block to construct usuable stuff...
AFRP name: first
-}
extendDown: Automaton i o -> Automaton (i,extra) (o,extra)
extendDown auto = case auto of
  Pure fun          -> Pure (\(i,extra) -> (fun i, extra))
  Stateful base fun -> Stateful base (\(i,extra) s -> (fun i s, extra))

{-| Connects the second output as input to itself, creating a loop. Now your automaton is stateful! :D
Does require a default value to put on the loop.
AFRP name: loop
-}
loop: s -> Automaton (i,s) (o,s) -> Automaton i o
loop base auto = case auto of
  Pure fun           -> Stateful base (curry fun)
  Stateful base2 fun -> -- fun: (i, s) -> s2 -> ((o, s), s2)
    let newFun = (\i (s,s2) ->
      let ((o, s'), s2') = fun (i, s) s2
      in (o, (s', s2'))) -- newFun: i -> (s, s2) -> (o, (s, s2))
    in Stateful (base, base2) newFun

{-| Runs the automaton on a given signal, like a lifted function.
Takes a default value for the output.
-}
run: Automaton i o -> o ->  Signal i -> Signal o
run auto baseOut input = case auto of
  Pure fun          -> lift fun input
  Stateful base fun -> lift fst
                         (foldp (\i (o, s) -> fun i s)
                           (baseOut, base) input)


-- Other frequently used functions/operators

{-| Easy shortcut for creating an automaton with state. Requires an
initial state and a step function to step the state forward. For
example, an automaton that counts how many steps it has taken would
look like this:

        count = Automaton a Int
        count = state 0 (\_ c -> c+1)

-}
state : s -> (i -> s -> s) -> Automaton i s
state base fun = loop base (pure (\(i,s) ->
                                    let s' = fun i s
                                    in (s',s')))

{-| Create an automaton with hidden state. Requires an initial state
and a step function to step the state forward and produce an output.
-}
hiddenState : s -> (i -> s -> (s,o)) -> Automaton i o
hiddenState base fun = loop base (pure (\(i,s) ->
                                          let (o,s') = fun i s
                                          in (s',o)))

{-| Like extendDown this function add an extra input that is ignored
and sent out again, only this extra input it added before the existing
input in stead of after.
AFRP name: second
-}
extendUp: Automaton i o -> Automaton (extra,i) (extra,o)
extendUp auto =
  let swap (a, b) = (b, a)
  in pure swap `andThen` extendDown auto `andThen` pure swap

{-| Parallel composition, stacking them up.
AFRP name: ***
-}
pair: Automaton i1 o1 -> Automaton i2 o2 -> Automaton (i1,i2) (o1,o2)
pair f g = extendDown f `andThen` extendUp g

{-| Combine two Automatons that work on the same kind of input.
AFRP name: &&&
-}
branch : Automaton i o1 -> Automaton i o2 -> Automaton i (o1,o2)
branch f g =
  let double = pure (\i -> (i,i))
  in double `andThen` pair f g

{-| Kind of like a list cons (::), adds an automaton to an automaton
that is already branched.
A building block for `combine`.
-}
combi: Automaton i o -> Automaton i [o] -> Automaton i [o]
combi a1 a2 = (a1 `branch` a2) `andThen` pure (uncurry (::))

{-| Combine a list of automatons into a single automaton that produces
a list.
-}
combine : [Automaton i o] -> Automaton i [o]
combine autos =
  let l = length autos
  in if l == 0
       then pure (\_ -> [])
       else foldr combi (last autos `andThen` pure (\a -> [a])) (take (l-1) autos)


-- Examples of automata

{-| Counts the number of steps taken. -}
count : Automaton a Int
count = state 0 (\_ c -> c + 1)

type Queue t = ([t],[t])
empty = ([],[])
enqueue x (en,de) = (x::en, de)
dequeue q = case q of
              ([],[]) -> Nothing
              (en,[]) -> dequeue ([], reverse en)
              (en,hd::tl) -> Just (hd, (en,tl))

{-| Computes the running average of the last n inputs.
@arg1 n
-}
average : Int -> Automaton Float Float
average k =
  let step n (ns,len,sum) =
          if len == k then stepFull n (ns,len,sum)
                      else ((enqueue n ns, len+1, sum+n), (sum+n) / (toFloat len+1))
      stepFull n (ns,len,sum) =
          case dequeue ns of
            Nothing -> ((ns,len,sum), 0)
            Just (m,ns') -> let sum' = sum + n - m
                            in ((enqueue n ns', len, sum'), sum' / toFloat len)
  in  hiddenState (empty,0,0) step
