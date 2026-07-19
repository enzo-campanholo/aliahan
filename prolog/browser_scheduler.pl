:- use_module(library(http/json)).
:- use_module(library(time)).
:- use_module(scheduler).

:- initialization(main, main).


main :-
        catch(run, Error, report_error(Error)).

run :-
        current_prolog_flag(argv, [InputPath]),
        setup_call_cleanup(open(InputPath, read, Stream, [encoding(utf8)]),
                           json_read_dict(Stream, Request),
                           close(Stream)),
        request_problem(Request, Courses, Today, Settings),
        (   solve_within(
                25,
                once(schedule(Courses, Today, Settings,
                              Entries, Conflicts, Score))
            )
        ->  maplist(entry_dict, Entries, EntryDicts),
            maplist(conflict_dict, Conflicts, ConflictDicts),
            score_dict(Score, ScoreDict),
            json_write_dict(current_output,
                            _{entries:EntryDicts,
                              conflicts:ConflictDicts,
                              score:ScoreDict}),
            nl
        ;   throw(error(domain_error(feasible_schedule, Request), _))
        ).

/*  call_with_time_limit/2 throws time_limit_exceeded, which
    library(clpfd)'s optimise/3 catches and absorbs, so a solve could
    keep running long past the limit. An alarm throwing a custom term
    propagates through clpfd unharmed. remove(false) keeps the alarm
    identifier valid so that remove_alarm/1 in the cleanup succeeds
    whether or not the alarm has fired.
*/
solve_within(Seconds, Goal) :-
        setup_call_cleanup(
            alarm(Seconds, throw(aliahan_timeout), Id, [remove(false)]),
            Goal,
            remove_alarm(Id)).

report_error(aliahan_timeout) :-
        format(user_error,
               'SWI-Prolog scheduler did not finish within 25 seconds~n', []),
        halt(1).
report_error(Error) :-
        message_to_string(Error, Message),
        format(user_error, '~s~n', [Message]),
        halt(1).


request_problem(Request, Courses, Today, Settings) :-
        date_string(Request.today, Today),
        weekend_mode(Request.include_weekends, Mode),
        Settings = settings(Mode, Request.deadline_slack_days),
        maplist(course_term, Request.courses, Courses).

weekend_mode(true, weekends).
weekend_mode(false, weekdays).

course_term(Dict, course(Id, Deadline, Prerequisites, Modules)) :-
        Id = Dict.id,
        date_string(Dict.deadline, Deadline),
        Prerequisites = Dict.prerequisite_ids,
        Modules = Dict.module_ids.

date_string(String, date(Year, Month, Day)) :-
        split_string(String, "-", "", Parts),
        maplist(number_string, [Year,Month,Day], Parts).


entry_dict(entry(CourseId, ModuleId, Date, Slot), Dict) :-
        date_text(Date, DateText),
        Dict = _{ course_id:CourseId,
                  module_id:ModuleId,
                  scheduled_date:DateText,
                  slot_index:Slot }.

conflict_dict(conflict(CourseId, Kind),
              _{course_id:CourseId, kind:Kind}).

score_dict(score(Overlaps, Peak, Spacing),
           _{overlaps:Overlaps, peak_load:Peak, spacing_error:Spacing}).

date_text(date(Year, Month, Day), Text) :-
        format(string(Text), '~|~`0t~d~4+-~|~`0t~d~2+-~|~`0t~d~2+',
               [Year,Month,Day]).
