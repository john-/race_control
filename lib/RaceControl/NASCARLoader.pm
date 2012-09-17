package NASCARLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

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


    $contents =~ s/\r//g;

    # E|63|540|R|C|334|334|0|1.5|Samsung Mobile 500||Fort Worth, TX|checkered||03:30:18|145.34|41|13|12|31|32|7|||||||tms|Quad-oval|Texas|Intermediate Track|43

    # R|359|11|29|1|true|0.000|0|Denny|Hamlin|334|30.13|12|325|783|190|Active|Active|Toyota|Fed Ex Ground|32|1||184.951||132.681|29.20||40.70|179.229|dhamlin00|0|0


    # what is used for the hash labels. This should be passed to this object
    @hashkeys = qw(rec_type tbd1 car start position tbd2 gap laps_down first_name last_name laps last_lap laps_led tbd4 tbd5 tbd6 status tbd7 model team tbd8 tbd9 tbd10 best_speed tbd11 avg_speed best_lap tbd12 avg_lap low_speed driver_id tbd13 tbd14);


    my %session = ();

    foreach (split /\n/, $contents) {

 	if (/^R\|/) {
	    #print "position info: $_\n";
	    my @values = split(/\|/);
	    foreach (@values) { s/^\ *//; };
	    #my @values = map { s/^\ *//; } split(/\|/);
	    #foreach (@values) { print "val: $_ "; }
	    #print "\n";

	    my %stats;
	    @stats{@hashkeys} = @values;

            # do some clean up / normalization

	    $stats{driver} = $stats{first_name} . ' ' . $stats{last_name};

	    $stats{status} =~ s/In Pits/Pit/ig;
	    $stats{status} =~ s/Active/Run/;
	    #$stats{status} =~ s/Pace_Laps/Pace/;

	    if ($stats{laps_down}) { $stats{gap} = "$stats{laps_down} laps" }
	    
	    # convert time from MM:SS to seconds
	    #$stats{last_lap} = $self->time_to_dec($stats{last_lap});
	    #$stats{best_lap} = $self->time_to_dec($stats{best_lap});

	    $stats{id} = $stats{car};

	    #print Dumper(%stats);

	    push @{$session{positions}}, \%stats;

	} elsif (/^E\|/) {
            #print "header: $_\n";
	    my @values = split(/\|/);

	    # TODO: flag vlaues other then "checkered" need to be validated
	    my $flag;
            my $abbrv = $values[12];
	    if ($abbrv eq 'green') { 
	        $flag = 'Green'
            } elsif ($abbrv eq 'yellow') {
                $flag = 'Yellow'
            } elsif ($abbrv eq 'red') {
                $flag = 'Red'
            } elsif ($abbrv eq 'checkered') {
                $flag = 'Checkered'
            } else {
                $flag = "$abbrv";
            }
	    if ($abbrv ne '') { $session{flag} = $flag };

	    #my $msg = $values[16];
            #$msg =~ s/^>//;
	    #$msg =~ s/^.* : //;

	    #$session{control_message} = $msg unless $msg =~ /^\S+ flag/i;
	    $session{event} = $values[9];
	    $session{time}  = $values[14];

	    #print"event: $values[0]\n";
	    #print Dumper(%session);
	    
        } else {
	    #print "garbage: $_\n";
        }


    }


    #print Dumper(@rows);


    #Logger->log($html);


    #Logger->log(Dumper($te_pos->rows));

    #%columns = %{$self->{config}{session}{fields}};




    #Logger->log(Dumper($te_race->rows->[0][1]));
    #($session{time}) = :\d\d:\d\d)/;
    #($session{remaining}) = $te_race->rows->[0][2] =~ /.*:(\d\d:\d\d:\d\d)/;

    #$session{series} = $series;
    #$session{event} = "$venue $event";
    #$session{flag} = $flag;

    Logger->log("series: |$session{series}| event: |$session{event}| flag: |$session{flag}| time: |$session{time}|");

    return %session;
}

1;
