:- begin_tests(scheduler).

:- use_module(scheduler).


test(respects_prerequisites) :-
        Courses = [course(intro, date(2026,3,25), [], [intro_1]),
                   course(advanced, date(2026,3,25), [intro], [advanced_1])],
        once(schedule(Courses, date(2026,3,19),
                      settings(weekends, 0), Entries)),
        Entries = [entry(intro, intro_1, date(2026,3,19), 0),
                   entry(advanced, advanced_1, date(2026,3,20), 0)].

test(skips_weekends) :-
        Courses = [course(c, date(2026,3,23), [], [one,two])],
        once(schedule(Courses, date(2026,3,20),
                      settings(weekdays, 0), Entries)),
        Entries = [entry(c, one, date(2026,3,20), 0),
                   entry(c, two, date(2026,3,23), 0)].

test(rejects_prerequisite_cycles, [fail]) :-
        Courses = [course(a, date(2026,3,25), [b], [a1]),
                   course(b, date(2026,3,25), [a], [b1])],
        schedule(Courses, date(2026,3,19), settings(weekends, 0), _).

test(rejects_unknown_prerequisites, [fail]) :-
        Courses = [course(a, date(2026,3,25), [missing], [a1])],
        schedule(Courses, date(2026,3,19), settings(weekends, 0), _).

test(rejects_an_elapsed_deadline, [fail]) :-
        Courses = [course(a, date(2026,3,18), [], [a1])],
        schedule(Courses, date(2026,3,19), settings(weekends, 0), _).

test(schedules_feasible_courses_beside_an_elapsed_course) :-
        Courses = [course(elapsed, date(2026,3,18), [], [old]),
                   course(feasible, date(2026,3,19), [], [current])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, Conflicts, score(0, 1, 0))),
        Entries = [entry(feasible, current, date(2026,3,19), 0)],
        Conflicts = [conflict(elapsed, impossible)].

test(reports_transitively_blocked_dependents) :-
        Courses = [course(elapsed, date(2026,3,18), [], [old]),
                   course(blocked, date(2026,3,20), [elapsed], [next]),
                   course(transitive, date(2026,3,21), [blocked], [last]),
                   course(feasible, date(2026,3,19), [], [current])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, Conflicts, _)),
        Entries = [entry(feasible, current, date(2026,3,19), 0)],
        Conflicts = [conflict(elapsed, impossible),
                     conflict(blocked, blocked),
                     conflict(transitive, blocked)].

test(uses_overlap_only_when_needed) :-
        Courses = [course(a, date(2026,3,20), [], [a1,a2,a3])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(Overlaps, Peak, _))),
        Overlaps = 1,
        Peak = 2,
        Entries = [entry(a, a1, date(2026,3,19), 0),
                   entry(a, a2, date(2026,3,19), 1),
                   entry(a, a3, date(2026,3,20), 0)].

test(minimizes_peak_load_before_spacing_error) :-
        Courses = [course(a, date(2026,3,20), [], [a1,a2,a3,a4,a5,a6])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(4, 3, 1))),
        maplist(entry_date, Entries, Dates),
        Dates = [date(2026,3,19),date(2026,3,19),date(2026,3,19),
                 date(2026,3,20),date(2026,3,20),date(2026,3,20)].

test(spreads_required_overlap_across_the_slack_window) :-
        Courses = [course(a, date(2026,3,23), [],
                          [a1,a2,a3,a4,a5,a6,a7,a8])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 2),
                      Entries, score(5, 3, _))),
        maplist(entry_date, Entries, Dates),
        Dates = [date(2026,3,19),date(2026,3,19),date(2026,3,19),
                 date(2026,3,20),date(2026,3,20),date(2026,3,20),
                 date(2026,3,21),date(2026,3,21)].

test(spaces_modules_evenly) :-
        Courses = [course(a, date(2026,4,15), [], [a1,a2,a3,a4])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(0, 1, 0))),
        maplist(entry_date, Entries, Dates),
        Dates = [date(2026,3,19),date(2026,3,28),
                 date(2026,4,6),date(2026,4,15)].

test(avoids_overlap_between_courses) :-
        Courses = [course(a, date(2026,3,22), [], [a1,a2]),
                   course(b, date(2026,3,22), [], [b1,b2])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(0, 1, _))),
        maplist(entry_date, Entries, Dates),
        sort(Dates, UniqueDates),
        same_length(Dates, UniqueDates).

test(stacks_modules_to_finish_by_the_slack_deadline) :-
        Courses = [course(a, date(2026,7,29), [],
                          [a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12])],
        once(schedule(Courses, date(2026,7,19), settings(weekends, 3),
                      Entries)),
        maplist(entry_date, Entries, Dates),
        maplist(date_ordinal_leq(date(2026,7,26)), Dates),
        length(Entries, 12).

test(stacks_inside_a_single_day_slack_window) :-
        Courses = [course(a, date(2026,3,20), [], [a1,a2])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 1),
                      Entries, score(1, 2, 0))),
        Entries = [entry(a, a1, date(2026,3,19), 0),
                   entry(a, a2, date(2026,3,19), 1)].

test(empty_slack_window_falls_back_to_the_true_deadline) :-
        Courses = [course(a, date(2026,3,20), [], [a1,a2])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 5),
                      Entries, [], _)),
        Entries = [entry(a, a1, date(2026,3,19), 0),
                   entry(a, a2, date(2026,3,20), 0)].

test(prerequisite_chain_respects_slack_deadlines) :-
        Courses = [course(base, date(2026,3,24), [], [base_1,base_2]),
                   course(follow, date(2026,3,28), [base],
                          [follow_1,follow_2])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 2),
                      Entries)),
        course_dates(Entries, base, BaseDates),
        course_dates(Entries, follow, FollowDates),
        last(BaseDates, BaseLast),
        FollowDates = [FollowFirst|_],
        last(FollowDates, FollowLast),
        date_ordinal_leq(date(2026,3,22), BaseLast),
        date_ordinal_leq(date(2026,3,26), FollowLast),
        \+ date_ordinal_leq(BaseLast, FollowFirst).

test(honours_deadline_slack_when_possible) :-
        Courses = [course(a, date(2026,3,22), [], [a1,a2])],
        once(schedule(Courses, date(2026,3,19),
                      settings(weekends, 1), Entries)),
        Entries = [entry(a, a1, date(2026,3,19), 0),
                   entry(a, a2, date(2026,3,21), 0)].

test(excess_slack_keeps_the_target_in_the_available_window) :-
        Courses = [course(a, date(2026,3,19), [], [a1])],
        once(schedule(Courses, date(2026,3,19),
                      settings(weekends, 100), Entries,
                      score(0, 1, 0))),
        Entries = [entry(a, a1, date(2026,3,19), 0)].

test(uses_the_last_weekday_before_a_weekend_deadline) :-
        Courses = [course(a, date(2026,3,21), [], [a1,a2])],
        once(schedule(Courses, date(2026,3,20),
                      settings(weekdays, 0), Entries,
                      score(1, 2, 0))),
        Entries = [entry(a, a1, date(2026,3,20), 0),
                   entry(a, a2, date(2026,3,20), 1)].

test(shared_prerequisite_unblocks_each_dependent) :-
        Courses = [course(first, date(2026,3,22), [], [first_1]),
                   course(left, date(2026,3,22), [first], [left_1]),
                   course(right, date(2026,3,22), [first], [right_1])],
        once(schedule(Courses, date(2026,3,19),
                      settings(weekends, 0), Entries)),
        Entries = [entry(first, first_1, date(2026,3,19), 0),
                   entry(left, left_1, date(2026,3,20), 0),
                   entry(right, right_1, date(2026,3,21), 0)].

test(completed_prerequisite_needs_no_calendar_day) :-
        Courses = [course(done, date(2026,3,18), [], []),
                   course(next, date(2026,3,19), [done], [next_1])],
        once(schedule(Courses, date(2026,3,19),
                      settings(weekends, 0), Entries)),
        Entries = [entry(next, next_1, date(2026,3,19), 0)].

test(no_remaining_modules) :-
        Courses = [course(done, date(2026,3,18), [], [])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0), [],
                      score(0, 0, 0))).

test(crosses_a_leap_day) :-
        Courses = [course(a, date(2028,3,1), [], [a1,a2,a3])],
        once(schedule(Courses, date(2028,2,28),
                      settings(weekends, 0), Entries)),
        maplist(entry_date, Entries, Dates),
        Dates = [date(2028,2,28),date(2028,2,29),date(2028,3,1)].

test(relaxes_peak_when_its_lower_bound_is_unreachable) :-
        Courses = [course(a, date(2026,3,19), [], [a1,a2,a3]),
                   course(b, date(2026,3,22), [], [b1])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(2, 3, _))),
        Entries = [entry(a, a1, date(2026,3,19), 0),
                   entry(a, a2, date(2026,3,19), 1),
                   entry(a, a3, date(2026,3,19), 2),
                   entry(b, b1, date(2026,3,20), 0)].

test(falls_back_to_plain_labeling_beyond_the_relaxation_ladder) :-
        Courses = [course(a, date(2026,3,19), [], [a1,a2,a3,a4,a5,a6]),
                   course(b, date(2026,3,25), [], [b1])],
        once(schedule(Courses, date(2026,3,19), settings(weekends, 0),
                      Entries, score(Overlaps, Peak, _))),
        length(Entries, 7),
        Overlaps >= 5,
        Peak >= 6.

test(rejects_a_prerequisite_chain_without_enough_days, [fail]) :-
        Courses = [course(a, date(2026,3,19), [], [a1]),
                   course(b, date(2026,3,19), [a], [b1])],
        schedule(Courses, date(2026,3,19), settings(weekends, 0), _).


entry_date(entry(_, _, Date, _), Date).

date_ordinal_leq(Limit, Date) :-
        scheduler:date_ordinal(Date, Ordinal),
        scheduler:date_ordinal(Limit, LimitOrdinal),
        Ordinal =< LimitOrdinal.

course_dates(Entries, CourseId, Dates) :-
        findall(Date, member(entry(CourseId, _, Date, _), Entries), Dates),
        Dates = [_|_].


:- end_tests(scheduler).
