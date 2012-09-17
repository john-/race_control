package CHAMPLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;

use Data::Dumper;

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    return $self;
}

sub get_state {
    my ($self, $info) = @_;
    
    #my $info = $self->_get_contents();

    $info =~ s/\r//g;


    # what is used for the hash labels. This should be passed to this object
    @hashkeys = qw(position car driver laps last_lap bl_num best_lap gap interval tbd1 tbd2 tbd3 tbd4 status last_speed best_speed total_time tbd5 tbd6 tbd7 tbd8 class tbd9 tbd10 tbd11);

# unused compared to ALMS: stops last_stop total_stop car_makemodel team tires notes


    my %session = ();

    foreach (split /\n/, $info) {

 	if (/^ +\d+\|/) {
	    #print "position info: $_\n";
	    my @values = split(/\|/);
	    foreach (@values) { s/^\ *//; };
	    #my @values = map { s/^\ *//; } split(/\|/);
	    #foreach (@values) { print "val: $_ "; }
	    #print "\n";

	    my %stats;
	    @stats{@hashkeys} = @values;

            # do some clean up / normalization

	    $stats{driver} =~ s/ \(R\)$//; # I don't care if rookie

	    $stats{status} =~ s/In Pit/Pit/;
	    $stats{status} =~ s/Active/Run/;
	    $stats{status} =~ s/Pace_Laps/Pace/;

	    # convert time from MM:SS to seconds
	    $stats{last_lap} = RaceControl::Utils::time_to_dec($stats{last_lap});
	    $stats{best_lap} = RaceControl::Utils::time_to_dec($stats{best_lap});

	    $stats{id} = $stats{car};

#	    print Dumper(%stats);

	    push @{$session{positions}}, \%stats;

	} elsif (/^</) {
            #print "header: $_\n";
	    my @values = split(/\|/);
	    #foreach (@values) { s/^\ *//; };

	    my $flag;
            my $abbrv = $values[5];
	    if ($abbrv eq 'G') { 
	        $flag = 'Green'
            } elsif ($abbrv eq 'Y') {
                $flag = 'Yellow'
            } elsif ($abbrv eq 'R') {
                $flag = 'Red'
            } elsif ($abbrv eq 'C') {
                $flag = 'Checkered'
            } else {
                $flag = "$abbrv";
            }
	    if ($abbrv ne '') { $session{flag} = $flag };

	    my $msg = $values[16];
            $msg =~ s/^>//;
	    $msg =~ s/^.* : //;
	    # CHAMP site likes to put flag info in control_message.  Ignore it.
	    $session{control_message} = $msg unless $msg =~ /^\S+ flag/i;
	    
        } else {
	    #print "garbage: $_\n";
        }
	

    }

    #print Dumper(%session);


    return %session;
}

1;
