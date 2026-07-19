/*  Course scheduling with CLP(FD).

    Courses are represented as:

        course(Id, Deadline, PrerequisiteIds, RemainingModuleIds)

    Dates are date(Year, Month, Day). An empty module list means that the
    course has already been completed. Settings are settings(weekends, Slack)
    or settings(weekdays, Slack).

    The core of the scheduler is a relation over finite-domain variables.
    Search first minimizes modules that share a day, then the busiest day,
    and finally the deviation from even spacing.
*/

:- module(scheduler, [schedule/4, schedule/5, schedule/6]).

:- use_module(library(clpfd)).
:- use_module(library(pairs)).
:- use_module(library(time)).


schedule(Courses, Today, Settings, Entries) :-
        schedule(Courses, Today, Settings, Entries, _).

schedule(Courses, Today, Settings, Entries, Score) :-
        schedule(Courses, Today, Settings, Entries, [], Score).

schedule(Courses, Today, Settings, Entries, Conflicts, Score) :-
        schedule_model(Courses, Today, Settings,
                       Plans, Days, Vars, Conflicts, Score),
        optimize(Vars, Score),
        plans_entries(Plans, Days, Entries).


schedule_model(Courses, Today, Settings,
               Plans, Days, Vars, Conflicts, Score) :-
        valid_problem(Courses, Today, Settings),
        phrase(active_courses(Courses), Active),
        schedulable_courses(Active, Courses, Today, Settings,
                            Schedulable, Conflicts),
        phrase(eligible_courses(Courses, Schedulable), Eligible),
        schedule_model_(Schedulable, Eligible, Today, Settings,
                        Plans, Days, Vars, Score).

/*  Branch-and-bound over all three objectives at once restarts the
    whole search for every 1-unit improvement and can take hours on
    larger instances. The model already posts tight lower bounds for
    Overlaps and Peak, so search instead pins both to their infima
    (relaxing them in small steps if pinning turns out infeasible) and
    only minimizes the spacing error, with plain labeling as a
    terminating last resort.
*/
optimize([], score(0, 0, 0)).
optimize(Vars, score(Overlaps, Peak, Spacing)) :-
        Vars = [_|_],
        fd_inf(Overlaps, OverlapInf),
        fd_inf(Peak, PeakInf),
        once(bounded_labeling(Vars, Overlaps, Peak, Spacing,
                              OverlapInf, PeakInf)).

bounded_labeling(Vars, Overlaps, Peak, Spacing, OverlapInf, PeakInf) :-
        member(OverlapSlack-PeakSlack, [0-0,0-1,0-2,1-2,2-2]),
        Overlaps #=< OverlapInf + OverlapSlack,
        Peak #=< PeakInf + PeakSlack,
        spacing_search(Vars, Spacing).
bounded_labeling(Vars, _, _, _, _, _) :-
        labeling([ffc,bisect], Vars).

/*  library(clpfd)'s optimise/3 catches time_limit_exceeded and treats
    it as "accept the best value found so far", so with a single min/1
    objective this is an anytime search: it yields the best spacing
    found within the limit, and fails if the limit expires before any
    solution is found (or the current bounds are infeasible).
*/
spacing_search(Vars, Spacing) :-
        catch(call_with_time_limit(
                  2,
                  once(labeling([ffc,bisect,min(Spacing)], Vars))),
              time_limit_exceeded,
              fail).

schedule_model_([], _, _, _, [], [], [], score(0, 0, 0)).
schedule_model_([Course|Courses], AllCourses, Today, Settings,
                Plans, Days, Vars, Score) :-
        Active = [Course|Courses],
        maplist(course_deadline_ordinal, Active, DeadlineOrdinals),
        max_list(DeadlineOrdinals, LastOrdinal),
        calendar_days(Today, LastOrdinal, Settings, Days),
        maplist(optimistic_start(AllCourses), Active, Starts),
        maplist(course_plan(Days, Settings), Starts, Active, Plans),
        course_states(AllCourses, Plans, States),
        maplist(plan_constraints(States), Plans),
        plans_penalties(Plans, SpacingPenalties),
        maximum_fd(SpacingPenalties, Spacing),
        plans_variables(Plans, Vars),
        plans_overlap_lower_bound(Plans, ForcedOverlaps),
        plans_usable_day_count(Plans, UsableDays),
        occupancy(Days, UsableDays, Vars, ForcedOverlaps, Overlaps, Peak),
        Score = score(Overlaps, Peak, Spacing).

/*  Days past every course's latest allowed finish can host nothing, so
    only days up to the highest reachable index count towards the
    overlap and peak lower bounds. Without this the search bounds are
    too optimistic whenever slack caps shrink the usable calendar.
*/
plans_usable_day_count(Plans, UsableDays) :-
        maplist(plan_last_supremum, Plans, Suprema),
        max_list(Suprema, MaxIndex),
        UsableDays is MaxIndex + 1.

plan_last_supremum(plan(_, _, _, _, _, Last, _, _), Supremum) :-
        fd_sup(Last, Supremum).


valid_problem(Courses, Today, settings(Days, Slack)) :-
        calendar_mode(Days),
        Slack #>= 0,
        ground(Courses-Today-Slack),
        valid_date(Today),
        maplist(valid_course, Courses),
        unique_course_ids(Courses),
        unique_module_ids(Courses),
        acyclic(Courses).

calendar_mode(weekdays).
calendar_mode(weekends).

valid_course(course(Id, Deadline, Prerequisites, Modules)) :-
        ground(Id-Prerequisites-Modules),
        valid_date(Deadline),
        is_list(Prerequisites),
        is_list(Modules).

unique_course_ids(Courses) :-
        maplist(course_id, Courses, Ids),
        sort(Ids, Unique),
        same_length(Ids, Unique).

unique_module_ids(Courses) :-
        maplist(course_modules, Courses, Modules0),
        append(Modules0, Modules),
        sort(Modules, Unique),
        same_length(Modules, Unique).

course_id(course(Id, _, _, _), Id).

course_modules(course(_, _, _, Modules), Modules).


acyclic(Courses) :-
        maplist(course_acyclic(Courses, []), Courses).

course_acyclic(Courses, Path,
               course(Id, _, Prerequisites, _)) :-
        maplist(dif(Id), Path),
        maplist(prerequisite_acyclic(Courses, [Id|Path]), Prerequisites).

prerequisite_acyclic(Courses, Path, Id) :-
        course_with_id(Courses, Id, Course),
        course_acyclic(Courses, Path, Course).

course_with_id([course(Id, Deadline, Prerequisites, Modules)|_], Id,
               course(Id, Deadline, Prerequisites, Modules)).
course_with_id([course(Id0, _, _, _)|Courses], Id, Course) :-
        dif(Id0, Id),
        course_with_id(Courses, Id, Course).


active_courses([]) --> [].
active_courses([Course|Courses]) -->
        active_course(Course),
        active_courses(Courses).

active_course(course(_, _, _, [])) --> [].
active_course(Course) -->
        { Course = course(_, _, _, [_|_]) },
        [Course].


schedulable_courses([], _, _, _, [], []).
schedulable_courses(Active, Courses, Today, Settings,
                    Schedulable, Conflicts) :-
        Active = [_|_],
        maplist(course_deadline_ordinal, Active, DeadlineOrdinals),
        max_list(DeadlineOrdinals, LastOrdinal),
        calendar_days(Today, LastOrdinal, Settings, Days),
        phrase(completed_states(Courses), Completed),
        classify_courses(Active, Completed, Days,
                         Schedulable, Conflicts).

completed_states([]) --> [].
completed_states([course(Id, _, _, [])|Courses]) -->
        [Id-done],
        completed_states(Courses).
completed_states([course(_, _, _, [_|_])|Courses]) -->
        completed_states(Courses).

classify_courses([], _, _, [], []).
classify_courses(Pending, States0, Days, Schedulable, Conflicts) :-
        split_ready_courses(Pending, States0, Ready, Blocked),
        Ready = [_|_],
        classify_ready(Ready, States0, States, Days,
                       ReadySchedulable, ReadyConflicts),
        classify_courses(Blocked, States, Days,
                         BlockedSchedulable, BlockedConflicts),
        append(ReadySchedulable, BlockedSchedulable, Schedulable),
        append(ReadyConflicts, BlockedConflicts, Conflicts).

split_ready_courses([], _, [], []).
split_ready_courses([Course|Courses], States, Ready, Blocked) :-
        Course = course(_, _, Prerequisites, _),
        (   maplist(state_known(States), Prerequisites)
        ->  Ready = [Course|Ready0],
            Blocked = Blocked0
        ;   Ready = Ready0,
            Blocked = [Course|Blocked0]
        ),
        split_ready_courses(Courses, States, Ready0, Blocked0).

state_known(States, Id) :-
        memberchk(Id-_, States).

classify_ready([], States, States, _, [], []).
classify_ready([Course|Courses], States0, States, Days,
               Schedulable, Conflicts) :-
        classify_course(Course, States0, Days,
                        State, CourseSchedulable, CourseConflicts),
        Course = course(Id, _, _, _),
        classify_ready(Courses, [Id-State|States0], States, Days,
                       MoreSchedulable, MoreConflicts),
        append(CourseSchedulable, MoreSchedulable, Schedulable),
        append(CourseConflicts, MoreConflicts, Conflicts).

classify_course(course(Id, _, Prerequisites, _), States, _,
                blocked, [], [conflict(Id, blocked)]) :-
        member(Prerequisite, Prerequisites),
        memberchk(Prerequisite-blocked, States),
        !.
classify_course(Course, States, Days, State, Schedulable, Conflicts) :-
        Course = course(Id, Deadline, Prerequisites, _),
        maplist(prerequisite_earliest_start(States),
                Prerequisites, Starts),
        max_list([0|Starts], Earliest),
        date_ordinal(Deadline, DeadlineOrdinal),
        index_at_most(Days, DeadlineOrdinal, -1, DeadlineIndex),
        (   Earliest =< DeadlineIndex
        ->  State = feasible(Earliest),
            Schedulable = [Course],
            Conflicts = []
        ;   State = blocked,
            Schedulable = [],
            Conflicts = [conflict(Id, impossible)]
        ).

prerequisite_earliest_start(States, Id, Start) :-
        memberchk(Id-State, States),
        earliest_start(State, Start).

earliest_start(done, 0).
earliest_start(feasible(Last), Start) :-
        Start is Last + 1.

eligible_courses([], _) --> [].
eligible_courses([Course|Courses], Schedulable) -->
        eligible_course(Course, Schedulable),
        eligible_courses(Courses, Schedulable).

eligible_course(Course, _) -->
        { Course = course(_, _, _, []) },
        [Course].
eligible_course(Course, Schedulable) -->
        { Course = course(_, _, _, [_|_]),
          memberchk(Course, Schedulable) },
        [Course].
eligible_course(Course, Schedulable) -->
        { Course = course(_, _, _, [_|_]),
          \+ memberchk(Course, Schedulable) },
        [].


course_deadline_ordinal(course(_, Deadline, _, _), Ordinal) :-
        date_ordinal(Deadline, Ordinal).

course_plan(Days, settings(_, Slack), OptimisticStart,
            course(Id, Deadline, Prerequisites, Modules),
            plan(Id, Prerequisites, Modules, Dates,
                 First, Last, Preferred, _)) :-
        date_ordinal(Deadline, DeadlineOrdinal),
        index_at_most(Days, DeadlineOrdinal, -1, DeadlineIndex),
        DeadlineIndex #>= 0,
        PreferredOrdinal #= DeadlineOrdinal - Slack,
        index_at_most(Days, PreferredOrdinal, -1, Preferred),
        same_length(Modules, Dates),
        Dates ins 0..DeadlineIndex,
        chain(Dates, #=<),
        Dates = [First|_],
        last(Dates, Last),
        slack_cap(OptimisticStart, Preferred, Last).

/*  Finishing by the slack-adjusted deadline is a hard bound whenever the
    course could start by then: same-course modules may share a day, so a
    course that can start in time can always finish in time. The earliest
    possible start is derived from prerequisites alone (ground), not from
    the search, so the optimizer cannot dodge the bound by starting late.
    An unreachable slack target (Preferred < OptimisticStart, including
    the empty-window Preferred = -1) falls back to the true deadline.
*/
slack_cap(OptimisticStart, Preferred, Last) :-
        (   OptimisticStart =< Preferred
        ->  Last #=< Preferred
        ;   true
        ).

optimistic_start(Courses, course(_, _, Prerequisites, _), Start) :-
        maplist(prerequisite_optimistic_start(Courses), Prerequisites,
                Starts),
        max_list([0|Starts], Start).

prerequisite_optimistic_start(Courses, Id, Start) :-
        course_with_id(Courses, Id, Course),
        Course = course(_, _, _, Modules),
        prerequisite_finish_start(Modules, Courses, Course, Start).

prerequisite_finish_start([], _, _, 0).
prerequisite_finish_start([_|_], Courses, Course, Start) :-
        optimistic_start(Courses, Course, Start0),
        Start is Start0 + 1.

index_at_most([], _, Index, Index).
index_at_most([day(Index0, _, Ordinal)|Days], Limit, _, Index) :-
        Ordinal #=< Limit,
        index_at_most(Days, Limit, Index0, Index).
index_at_most([day(_, _, Ordinal)|_], Limit, Index, Index) :-
        Ordinal #> Limit.


course_states([], _, []).
course_states([course(Id, _, _, Modules)|Courses], Plans,
              [Id-State|States]) :-
        module_state(Modules, Id, Plans, State),
        course_states(Courses, Plans, States).

module_state([], _, _, done).
module_state([_|_], Id, Plans, active(Last)) :-
        plan_with_id(Plans, Id, Plan),
        Plan = plan(_, _, _, _, _, Last, _, _).

plan_with_id([plan(Id, Prerequisites, Modules, Dates,
                  First, Last, Preferred, Penalties)|_], Id,
             plan(Id, Prerequisites, Modules, Dates,
                  First, Last, Preferred, Penalties)).
plan_with_id([plan(Id0, _, _, _, _, _, _, _)|Plans], Id, Plan) :-
        dif(Id0, Id),
        plan_with_id(Plans, Id, Plan).

state_with_id([Id-State|_], Id, State).
state_with_id([Id0-_|States], Id, State) :-
        dif(Id0, Id),
        state_with_id(States, Id, State).


plan_constraints(States,
                 plan(_, Prerequisites, _, Dates,
                      First, _, Preferred, Penalties)) :-
        maplist(prerequisite_candidate(States, First),
                Prerequisites, Starts),
        maximum_fd([0|Starts], Earliest),
        First #>= Earliest,
        TargetEnd #= max(Earliest, Preferred),
        spacing_penalties_for(Dates, Earliest, TargetEnd, Penalties).

prerequisite_candidate(States, First, Id, Start) :-
        state_with_id(States, Id, State),
        prerequisite_state(State, First, Start).

prerequisite_state(done, _, 0).
prerequisite_state(active(Last), First, Start) :-
        Last #< First,
        Start #= Last + 1.

maximum_fd([X], X).
maximum_fd([X,Y|Xs], Maximum) :-
        Maximum0 #= max(X, Y),
        maximum_fd([Maximum0|Xs], Maximum).

spacing_penalties_for([Date], Earliest, _, [Penalty]) :-
        Penalty #= abs(Date - Earliest).
spacing_penalties_for([First,Second|Dates], Earliest, TargetEnd, Penalties) :-
        ModuleDates = [First,Second|Dates],
        length(ModuleDates, ModuleCount),
        Scale #= ModuleCount - 1,
        spacing_penalties(ModuleDates, Earliest, TargetEnd,
                          Scale, 0, Penalties).

spacing_penalties([], _, _, _, _, []).
spacing_penalties([Date|Dates], Earliest, TargetEnd,
                  Scale, Index, [Penalty|Penalties]) :-
        Offset #= Index*(TargetEnd - Earliest) div Scale,
        Target #= Earliest + Offset,
        Penalty #= abs(Date - Target),
        Index1 #= Index + 1,
        spacing_penalties(Dates, Earliest, TargetEnd,
                          Scale, Index1, Penalties).


plans_variables(Plans, Vars) :-
        phrase(plan_variables(Plans), Vars).

plan_variables([]) --> [].
plan_variables([plan(_, _, _, Dates, _, _, _, _)|Plans]) -->
        Dates,
        plan_variables(Plans).

plans_penalties(Plans, Penalties) :-
        phrase(plan_penalties(Plans), Penalties).

plan_penalties([]) --> [].
plan_penalties([plan(_, _, _, _, _, _, _, Penalties)|Plans]) -->
        Penalties,
        plan_penalties(Plans).

plans_overlap_lower_bound(Plans, LowerBound) :-
        maplist(plan_overlap_lower_bound, Plans, LowerBounds),
        sum_list(LowerBounds, LowerBound).

plan_overlap_lower_bound(
        plan(_, _, Modules, _, First, Last, _, _), LowerBound) :-
        length(Modules, ModuleCount),
        fd_inf(First, FirstInfimum),
        fd_sup(Last, LastSupremum),
        Window is LastSupremum - FirstInfimum + 1,
        LowerBound is max(0, ModuleCount - Window).

occupancy(Days, UsableDays, Vars, ForcedOverlaps, Overlaps, Peak) :-
        length(Vars, ModuleCount),
        same_length(Days, Counts),
        Counts ins 0..ModuleCount,
        days_indices(Days, Indices),
        pairs_keys_values(Cardinalities, Indices, Counts),
        global_cardinality(Vars, Cardinalities),
        maplist(overlap_count, Counts, Extra),
        sum(Extra, #=, Overlaps),
        maximum_fd(Counts, Peak),
        Overlaps #>= max(0, ModuleCount - UsableDays),
        Overlaps #>= ForcedOverlaps,
        Peak #>= (ModuleCount + UsableDays - 1) div UsableDays.

days_indices(Days, Indices) :-
        maplist(day_index, Days, Indices).

day_index(day(Index, _, _), Index).

overlap_count(Count, Extra) :-
        Extra #= max(0, Count - 1).


plans_entries(Plans, Days, Entries) :-
        phrase(plan_pairs(Plans), Pairs0),
        keysort(Pairs0, Pairs),
        group_pairs_by_key(Pairs, Groups),
        phrase(entry_groups(Groups, Days), Entries).

plan_pairs([]) --> [].
plan_pairs([plan(CourseId, _, Modules, Dates, _, _, _, _)|Plans]) -->
        module_pairs(Modules, Dates, CourseId),
        plan_pairs(Plans).

module_pairs([], [], _) --> [].
module_pairs([Module|Modules], [Date|Dates], CourseId) -->
        [Date-(CourseId-Module)],
        module_pairs(Modules, Dates, CourseId).

entry_groups([], _) --> [].
entry_groups([Index-Modules|Groups], Days) -->
        { memberchk(day(Index, Date, _), Days) },
        day_entries(Modules, Date, 0),
        entry_groups(Groups, Days).

day_entries([], _, _) --> [].
day_entries([CourseId-Module|Modules], Date, Slot) -->
        [entry(CourseId, Module, Date, Slot)],
        { Slot1 #= Slot + 1 },
        day_entries(Modules, Date, Slot1).


calendar_days(Today, LastOrdinal, settings(Mode, _), Days) :-
        date_ordinal(Today, TodayOrdinal),
        calendar_days(Today, TodayOrdinal, LastOrdinal,
                      Mode, 0, Days).

calendar_days(Date, Ordinal, LastOrdinal, _, _, []) :-
        Ordinal #> LastOrdinal,
        valid_date(Date).
calendar_days(Date, Ordinal, LastOrdinal, Mode, Index, Days) :-
        Ordinal #=< LastOrdinal,
        day_kind(Mode, Ordinal, Kind),
        calendar_day(Kind, Date, Ordinal, Index, Days, Rest, Index1),
        next_date(Date, Next),
        Ordinal1 #= Ordinal + 1,
        calendar_days(Next, Ordinal1, LastOrdinal,
                      Mode, Index1, Rest).

calendar_day(allowed, Date, Ordinal, Index,
             [day(Index, Date, Ordinal)|Days], Days, Index1) :-
        Index1 #= Index + 1.
calendar_day(skipped, _, _, Index, Days, Days, Index).

day_kind(weekends, _, allowed).
day_kind(weekdays, Ordinal, Kind) :-
        Weekday #= Ordinal mod 7,
        zcompare(Order, Weekday, 5),
        weekday_kind(Order, Kind).

weekday_kind(<, allowed).
weekday_kind(=, skipped).
weekday_kind(>, skipped).


valid_date(date(Year, Month, Day)) :-
        Year #>= 1,
        Month in 1..12,
        indomain(Month),
        days_in_month(Year, Month, Days),
        Day in 1..Days,
        indomain(Day).

date_ordinal(date(Year, Month, Day), Ordinal) :-
        valid_date(date(Year, Month, Day)),
        Year0 #= Year - 1,
        days_before_month(Month, BeforeMonth),
        leap_offset(Year, Month, Leap),
        Ordinal #= 365*Year0 + Year0 div 4 - Year0 div 100 +
                   Year0 div 400 + BeforeMonth + Leap + Day - 1.

days_before_month(1, 0).
days_before_month(2, 31).
days_before_month(3, 59).
days_before_month(4, 90).
days_before_month(5, 120).
days_before_month(6, 151).
days_before_month(7, 181).
days_before_month(8, 212).
days_before_month(9, 243).
days_before_month(10, 273).
days_before_month(11, 304).
days_before_month(12, 334).

leap_offset(Year, Month, Leap) :-
        leap_year(Year, IsLeap),
        zcompare(Order, Month, 2),
        leap_offset_(Order, IsLeap, Leap).

leap_offset_(<, _, 0).
leap_offset_(=, _, 0).
leap_offset_(>, IsLeap, IsLeap).

leap_year(Year, IsLeap) :-
        DivisibleBy4 #<==> Year mod 4 #= 0,
        DivisibleBy100 #<==> Year mod 100 #= 0,
        DivisibleBy400 #<==> Year mod 400 #= 0,
        IsLeap #<==> DivisibleBy4 #/\
                     (#\ DivisibleBy100 #\/ DivisibleBy400).

days_in_month(_, 1, 31).
days_in_month(Year, 2, Days) :-
        leap_year(Year, Leap),
        Days #= 28 + Leap.
days_in_month(_, 3, 31).
days_in_month(_, 4, 30).
days_in_month(_, 5, 31).
days_in_month(_, 6, 30).
days_in_month(_, 7, 31).
days_in_month(_, 8, 31).
days_in_month(_, 9, 30).
days_in_month(_, 10, 31).
days_in_month(_, 11, 30).
days_in_month(_, 12, 31).

next_date(date(Year, Month, Day), Next) :-
        days_in_month(Year, Month, Last),
        zcompare(Order, Day, Last),
        next_date_(Order, Year, Month, Day, Next).

next_date_(<, Year, Month, Day, date(Year, Month, Day1)) :-
        Day1 #= Day + 1.
next_date_(=, Year, Month, _, Next) :-
        zcompare(Order, Month, 12),
        next_month(Order, Year, Month, Next).

next_month(<, Year, Month, date(Year, Month1, 1)) :-
        Month1 #= Month + 1.
next_month(=, Year, _, date(Year1, 1, 1)) :-
        Year1 #= Year + 1.
