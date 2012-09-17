package GRANDAMLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;

use HTML::Clean;
use Data::Dumper;
use POE::Component::Logger;

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    return $self;
}

sub get_state {
    my ($self, $contents) = @_;


    $contents =~ s/\<BR\>/\n/g;

    #print "$contents\n\n\n";

    # May 14, 2011 - 10|37|59|AM|EDT
    # 1500|2355|R|1|Rolex Series|B|Bosch Engineering 250|2:45|Virginia International Raceway|Alton|VA|3.270 mi|0.0|http://www.grand-am.com/|/images/tracks/TRACKLOGO-Virginia1.jpg|/images/tracks/track_virginia.gif|
    # NONE|NONE
    # NONE|#
  # http://www.grand-am.com/schedule/results.cfm?series=r&eid=2355&sid=1665|Practice 4 (Results)|http://www.grand-am.com/schedule/results.cfm?series=r&eid=2355&sid=1565|Qualifying 1 (Results)|http://www.grand-am.com/schedule/results.cfm?series=r&eid=2355&sid=1642|Practice 3 (Results)|http://www.grand-am.com/schedule/results.cfm?series=r&eid=2355&sid=1641|Practice 2 (Results)|http://www.grand-am.com/schedule/results.cfm?series=r&eid=2355&sid=1640|Practice 1 (Results)
    #0|Blue|00:00:00|0|0|0|0|00:00:00|0|
    # 0|U|59|GT|0|Davis / Keen|0||Brumos Racing||0.000|00.000|0.000|00.000|0|0|Porsche GT3
    # 0|U|77|DP|0|Frisselle / Richard|0||Doran Racing||0.000|00.000|0.000|00.000|0|0|Ford / Dallara
    # 0|U|57|GT|0|Liddell / Magnussen|0||Stevenson Motorsports||0.000|00.000|0.000|00.000|0|0|Camaro GT.R
    # 0|U|43|GT|0|Nonnamaker / Nonnamaker / Nonnamaker|0||Team Sahlen||0.000|00.000|0.000|00.000|0|0|Mazda RX-8
    # v0|U|42|GT|0|Gidley / Nonnamaker|0||Team Sahlen||0.000|00.000|0.000|00.000|0|0|Mazda RX-8
    # 0|U|41|GT|0|Cameron / Gue|0||Dempsey Racing||0.000|00.000|0.000|00.000|0|0|Mazda RX-8
    # 0|U|40|GT|0|Dempsey / Foster|0||Dempsey Racing||0.000|00.000|0.000|00.000|0|0|Mazda RX-8


    # what is used for the hash labels. This should be passed to this object
    @hashkeys = qw(position status car class class_pos driver laps gap team interval last_lap last_speed best_lap best_speed tbd5 tbd6 model);

    my %session = ();

    my $dummy_position = 0;  # Grand-Am doesn't always fill position value
                            # so assign an arbitrary one
    foreach (split /\n/, $contents) {

 	if (/^\d+\|\w\|/) {
	    #print "position info: $_\n";
	    my @values = split(/\|/);
	    #foreach (@values) { s/^\ *//; };
	    #my @values = map { s/^\ *//; } split(/\|/);
	    #foreach (@values) { print "val: $_ "; }
	    #print "\n";

	    my %stats;
	    @stats{@hashkeys} = @values;

            # do some clean up / normalization

	    if ($stats{position} == 0) {$stats{position} = ++$dummy_position }

	    #$stats{driver} = $stats{first_name} . ' ' . $stats{last_name};

	    # some status seen so far:
	    # U : after practice was over
	    # S : I think this is "no change in position"
	    # I : Improve position
	    # L : Lose position
	    $stats{status} =~ s/[SIL]/Run/;
	    
	    #$stats{status} =~ s/In Pits/Pit/ig;
	    #$stats{status} =~ s/U/Unknown/;   # after practice status
	    #$stats{status} =~ s/Pace_Laps/Pace/;

	    #if ($stats{laps_down}) { $stats{gap} = "$stats{laps_down} laps" }
	    
	    # convert time from MM:SS to seconds
	    $stats{last_lap} = RaceControl::Utils::time_to_dec($stats{last_lap});
	    $stats{best_lap} = RaceControl::Utils::time_to_dec($stats{best_lap});

	    $stats{id} = $stats{car};

	    #print Dumper(%stats);

	    push @{$session{positions}}, \%stats;
	} elsif (/^\d+\|\d+\|/) {
            #print "header1: $_\n";
	    my @values = split(/\|/);

	    $session{series} = $values[4];
	    $session{event} = $values[6];
	    $session{venue} = $values[8];
	} elsif (/^\d+\|\D+\|/) {
            #print "header2: $_\n";
	    my @values = split(/\|/);

	    # TODO: flag vlaues other then "checkered" need to be validated
	    $session{flag} = $values[1];

	    #my $msg = $values[16];
            #$msg =~ s/^>//;
	    #$msg =~ s/^.* : //;

	    #$session{control_message} = $msg unless $msg =~ /^\S+ flag/i;
	    $session{time}  = $values[2];

	    #print"event: $values[0]\n";
	    #print Dumper(%session);
        } else {
	    #print "garbage: $_\n";
        }


    }

    Logger->log("series: |$session{series}| event: |$session{event}| flag: |$session{flag}| time: |$session{time}|");
    
    #print Dumper(%session);

    return %session;
}

1;
