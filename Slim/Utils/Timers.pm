package Slim::Utils::Timers;

# $Id$

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use Scalar::Util qw(blessed);

use Slim::Utils::Misc;
use Slim::Utils::PerfMon;

# Timers are stored in a list of hashes containing:
# - the time at which the timer should fire, 
# - a reference to an object
# - a reference to the function,
# - and a list of arguments.
#
# Two classes of timer exist - Normal timers and High Priority timers
# - High priority timers that are due are always execute first, even if a normal timer 
#   is due at an earlier time.
# - Functions assigned for callback on a normal timer may call ::idleStreams
# - Any normal timers which are due will not be executed if another normal timer is
#   currently being executed.
# - High priority timers are only blocked from execution if another High Priority
#   timer is executing (this should not occur).  They are intended for animation
#   routines which should run within ::idleStreams.
#
# Timers are checked whenever we come out of select.
  
our @normalTimers = ();
our @highTimers = ();
  
my $nextNormal;
my $nextHigh;
  
my $checkingNormalTimers = 0; # Semaphore to avoid normal timer callbacks executing inside each other
my $checkingHighTimers = 0;   # Semaphore for high priority timers

our $timerLate = Slim::Utils::PerfMon->new('Timer Late', [0.002, 0.005, 0.01, 0.015, 0.025, 0.05, 0.1, 0.5, 1, 5]);
our $timerLength = Slim::Utils::PerfMon->new('Timer Length', [0.002, 0.005, 0.01, 0.015, 0.025, 0.05, 0.1, 0.5, 1, 5]);
  
#
# Call any pending timers which have now elapsed.
#
sub checkTimers {

	# check High Priority timers first (animation)
	
	# return if already inside one
	if ($checkingHighTimers) {
	
		$::d_time && msg("blocked checking high timers - already processing a high timer!\n");
		return;
	}

	$checkingHighTimers = 1;

	my $now = Time::HiRes::time();
	my $fired = 0;

	while (defined($nextHigh) && ($nextHigh <= $now)) {

		my $high_timer = shift(@highTimers);
		$nextHigh = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
		$fired++;

		my $high_subptr = $high_timer->{'subptr'};
		my $high_objRef = $high_timer->{'objRef'};
		my $high_args   = $high_timer->{'args'};
	
		$::d_time && msg("firing high timer " . ($now - $high_timer->{'when'}) . " late.\n");
	
		no strict 'refs';

		&$high_subptr($high_objRef, @{$high_args});
	}

	$checkingHighTimers = 0;

	return if $fired;

	# completed check of High Priority timers

	if ($Slim::Player::SLIMP3::SLIMP3Connected && !$::scanOnly) {
		Slim::Networking::SliMP3::Protocol::readUDP();
	}
	
	# Check Normal timers - return if already inside one
	if ($checkingNormalTimers) {
		$::d_time && msg("blocked checking normal timers - already processing a normal timer!\n");
		return;
	}

	$checkingNormalTimers = 1;
  
	if (defined($nextNormal) && ($nextNormal <= $now)) {

		my $timer = shift(@normalTimers);
		$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;

		$::d_time && msg("firing timer " . ($now - $timer->{'when'}) . " late.\n");
		$::perfmon && $timerLate->log($now - $timer->{'when'});

		my $subptr = $timer->{'subptr'};
		my $objRef = $timer->{'objRef'};
		my $args   = $timer->{'args'};
	
		&$subptr($objRef, @{$args});

		$::perfmon && $timerLength->log(Time::HiRes::time() - $now);
	}

	$checkingNormalTimers = 0;
}

#
# Adjust all timers time by a given delta
# Called when time skips backwards and we need to adjust the timers respectively.
#
sub adjustAllTimers {
	my $delta = shift;
	
	$::d_time && msg("adjustAllTimers: time travel!");
	foreach my $timer (@highTimers, @normalTimers) {
		$timer->{'when'} = $timer->{'when'} + $delta;
	}
	$nextHigh = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
	$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;
}

#
# Return the time until the next timer is set to go off, 0 if overdue
# Return nothing if there are no timers
#
sub nextTimer {

	my $next = (defined($nextNormal) && !$checkingNormalTimers) ? $nextNormal : undef;
	
	if (defined($nextHigh) && (!defined($next) || $nextHigh < $next) && !$checkingHighTimers ) {
		$next = $nextHigh;
	}
	return undef if !defined $next;

	my $delta = $next - Time::HiRes::time();
	
	# return 0 if the timer is overdue
	$delta = 0 if ($delta <=0);
	
	return $delta;
}	

#
#  For debugging - prints out a list of all pending timers
#
sub listTimers {
	msg("High timers: \n");

	foreach my $timer (@highTimers) {

		msg(join("\t", $timer->{'objRef'}, $timer->{'when'}, $timer->{'subptr'}, "\n"));
	}

	msg("Normal timers: \n");

	foreach my $timer (@normalTimers) {

		msg(join("\t", $timer->{'objRef'}, $timer->{'when'}, $timer->{'subptr'}, "\n"));
	}
}

#
#  Schedule a High Priority timer to fire after $when, calling $subptr with
#  arguments $objRef and @args.  Returns a reference to the timer so that it can
#  be killed specifically later.
#
sub setHighTimer {
	my ($objRef, $when, $subptr, @args) = @_;

	if ($::d_time) {

		my $now = Time::HiRes::time();

		msg("settimer High: $subptr, now: $now, time: $when \n");

		if ($when < $now) {
			msg("}{}{}{}{}{}{}{}{}{}  Set a timer in the past!\n");
		}
	}

	# The list of timers is maintained in sorted order, so
	# we only have to check the head.

	# Find the slot where we should insert this new timer
	my $i = 0;

	foreach my $timer (@highTimers) { 

		last if ($timer->{'when'} > $when);
		$i++;
	}

	my $newtimer = {
		'objRef' => $objRef,
		'when'   => $when,
		'subptr' => $subptr,
		'args'   => \@args,
	};

	$nextHigh = $when if $i == 0;

	splice(@highTimers, $i, 0, $newtimer);

	return $newtimer;
}

#
#  Schedule a Normal Priority timer to fire after $when, calling $subptr with
#  arguments $objRef and @args.  Returns a reference to the timer so that it can
#  be killed specifically later.
#
sub setTimer {
	my ($objRef, $when, $subptr, @args) = @_;

	if ($::d_time) {
		my $now = Time::HiRes::time();
		msg("settimer Normal: $subptr, now: $now, time: $when \n");
		if ($when < $now) {
			msg("}{}{}{}{}{}{}{}{}{}  Set a timer in the past!\n");
		}
	}

	# The list of timers is maintained in sorted order, so
	# we only have to check the head.

	# Find the slot where we should insert this new timer
	my $i = 0;

	foreach my $timer (@normalTimers) { 
		last if ($timer->{'when'} > $when);
		$i++;
	}

	my $newtimer = {
		'objRef' => $objRef,
		'when'   => $when,
		'subptr' => $subptr,
		'args'   => \@args,
	};

	$nextNormal = $when if $i == 0;

	splice(@normalTimers, $i, 0, $newtimer);

	my $numtimers = (@normalTimers);

	if ($numtimers > 500) {
		die "Insane number of timers: $numtimers\n";		
	}

	return $newtimer;
}

#
#  Compares a timer with an object and function reference. Returns 1 if the
#  time matches the object and the function (if defined), 0 otherwise.
#
sub matchedTimer {
	my $timer  = shift;
	my $objRef = shift;
	my $subptr = shift;

	if (defined $timer && $timer->{'objRef'} eq $objRef) {

		if (defined $subptr && $timer->{'subptr'} eq $subptr) {

			return 1;

		} elsif (defined $subptr && $timer->{'subptr'} ne $subptr) {

			return 0;
		}

		return 1;
	}

	return 0;
}

#
# Throw out any pending timers (Normal or High) that match the objRef and the 
# subroutine
#
sub killTimers {
	my $objRef = shift || return;
	my $subptr = shift || return;

	my $i = 0;
	my $killed = 0;
	
	while (my $timer = $highTimers[$i]) {

		if (matchedTimer($timer, $objRef, $subptr)) {

			splice( @highTimers, $i, 1);
			$killed++;

		} else {

			$i++;
		}
	}

	$i = 0;

	while (my $timer = $normalTimers[$i]) {

		if (matchedTimer($timer, $objRef, $subptr)) {

			splice( @normalTimers, $i, 1);
			$killed++;

		} else {

			$i++;
		}
	}

	$nextHigh   = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
	$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;

	return $killed;
}

#
# Throw out any pending timers (Normal or High) that match the objRef and the 
# subroutine. Optimized version to use when callers knows a single timer matches.
#
sub killOneTimer {
	my $objRef = shift || return;
	my $subptr = shift || return;

	my $i = 0;

	while (my $timer = $highTimers[$i]) {

		if (matchedTimer($timer, $objRef, $subptr)) {

			splice( @highTimers, $i, 1);

			if ($i == 0) {
			    $nextHigh = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
			}

			return
		}

		$i++;
	}

	$i = 0;

	while (my $timer = $normalTimers[$i]) {

		if (matchedTimer($timer, $objRef, $subptr)) {

			splice( @normalTimers, $i, 1);

			if ($i == 0) {

			    	$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;
			}

			return
		}

		$i++;
	}
}

#
# Throw out all pending timers (Normal or High) matching the objRef.
#
sub forgetTimer {
	my $objRef = shift;
	my $count;

	$count = scalar(@highTimers);

	for (my $i = 0; $i < $count; $i++) {

		if (matchedTimer($highTimers[$i], $objRef)) {

			splice( @highTimers, $i, 1);
			redo;
		}
	}

	$count = scalar(@normalTimers);

	for (my $i = 0; $i < $count; $i++) {

#		if (matchedTimer($highTimers[$i], $objRef)) {
		if (matchedTimer($normalTimers[$i], $objRef)) {

			splice( @normalTimers, $i, 1);
			redo;
		}
	}

	$nextHigh   = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
	$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;
}

#
# Kill a specific timer
#
sub killSpecific {
	my $timer = shift;
	my $count;

	$count = scalar(@highTimers);

	for (my $i = 0; $i < $count; $i++) {

		if ($highTimers[$i] == $timer) {

			splice( @highTimers, $i, 1);

			if ($i == 0) {
			    	$nextHigh = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
			}

			return 1;
		}
	}

	$count = scalar(@normalTimers);

	for (my $i = 0; $i < $count; $i++) {

		if ($normalTimers[$i] == $timer) {

			splice( @normalTimers, $i, 1);

			if ($i == 0) {
			    	$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;
			}

			return 1;
		}
	}	

	errorMsg("attempted to delete non-existent timer: $timer\n");

	return 0;
}

#
# Count the matching timers for a given objRef and subroutine
#
sub pendingTimers {
	my $objRef = shift;
	my $subptr = shift;
	my $count = 0;

	# count pending matching timers 
	foreach my $timer (@highTimers, @normalTimers) {

		if (matchedTimer($timer, $objRef, $subptr)) {
			$count++;
		}
	}

	return $count;
}

#
# Fire the first timer matching a client/subptr
#
sub firePendingTimer {
	my $objRef = shift;
	my $subptr = shift;
	my $foundTimer;
	my $count;

	# find first pending matching timers 
	$count = scalar(@highTimers);

	for (my $i = 0; $i < $count; $i++) {

		if (matchedTimer($highTimers[$i], $objRef, $subptr)) {

			$foundTimer = splice( @highTimers, $i, 1);

			if ($i == 0) {

			    	$nextHigh = defined($highTimers[0]) ? $highTimers[0]->{'when'} : undef;
			}

			last;
		}
	}

	if (!defined $foundTimer) {

		$count = scalar(@normalTimers);

		for (my $i = 0; $i < $count; $i++) {

#			if (matchedTimer($highTimers[$i], $objRef, $subptr)) {
			if (matchedTimer($normalTimers[$i], $objRef, $subptr)) {

				$foundTimer = splice( @normalTimers, $i, 1);

				if ($i == 0) {

			    		$nextNormal = defined($normalTimers[0]) ? $normalTimers[0]->{'when'} : undef;
				}

				last;
			}
		}
	}
	
	if (defined $foundTimer) {

		return &$subptr($objRef, @{$foundTimer->{'args'}});
	}
}

1;

__END__
