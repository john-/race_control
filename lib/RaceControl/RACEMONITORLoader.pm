package RACEMONITORLoader;

# needed for modules local to RaceControl
use FindBin qw($Bin);
use lib "$Bin/../lib";
use RaceControl::Utils;

use POE::Filter::CSV;
#use HTML::Clean;
#use HTML::TableExtract;
use Data::Dumper;
use POE::Component::Logger;

sub new {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;

    my $fields_as_string = $self->{config}{session}{series}{$self->{series}}{fields};
    if ($fields_as_string eq '') { # default if field list not conf for series
        $fields_as_string = $self->{config}{session}{defaultfields};
    }
    @{$self->{fields}} = split / /, $fields_as_string;

    $self->{field} = ();  # Store car/drive info
    $self->{order} = [];   # Running order
    $self->{class} = ();   # Car class information
    $self->{carryover} = '';   # from previous time called
    
    return $self;
}


my @cleanups = (
    [ driver     => qr{\(M\)}             ], # sometimes there is a "(M)"
    [ driver     => qr{\(R\)}             ], # Don't care if they are a rookie
    [ best_speed => qr{\+}                ], # sometimes there is a "+"
    [ position   => qr{\+}                ],
    [ status     => qr{\A\z},       'Run' ], # not all series track status
    [ status     => qr{Active}i,    'Run' ],
    [ status     => qr{In Pit}i,    'Pit' ],
    [ status     => qr{Pace_Laps}i, 'Pace'],
    );

sub get_state {
    my ($self, $contents) = @_;

    $contents =~ s/\r//g;
    
    my %session;

    $contents = $self->{carryover} . $contents;

    my @results = split(/\n/, $contents);
    if (chomp($contents)) {
        $self->{carryover} = '';
    } else {
        $self->{carryover} = pop @results;  # the last item is partial CSV record
    }

    my $filter = POE::Filter::CSV->new( { binary => 1 }); # binary for crazy chars

    my $results_ref = $filter->get( [@results] );

    #Logger->log(Dumper($results_ref));

    foreach $row (@$results_ref) {
        #print Dumper($row);
	#print "row[0]: $row->[0]\n";
    
	my $rec = $row->[0];
	if ($rec eq '$C') { # car class
	    $self->{class}{$row->[1]} = $row->[2];
	    #print "class: " . $self->{class}{$row->[1]}."\n";
	} elsif ($rec eq '$COMP') { # competitor
	    $self->{field}{$row->[1]}{class}  = $self->{class}{$row->[3]};
	    $self->{field}{$row->[1]}{driver} = "$row->[4] $row->[5]";
	} elsif ($rec eq '$G') {  # order by position
	    my $pos = $row->[1];
	    my $car = $row->[2];
	    my $laps = $row->[3];
	    Logger->log("got a G record for car: $car  pos: $pos");
	    if ($laps <= $self->{field}{$car}{laps}) {
		#next;  # idea is that G records repeated once with lower lap num
		        # this broke oldoys
            }
	    Logger->log("Checking against pos: $pos car: $car (laps: $laps, max laps ".$self->{field}{$car}{laps}.")");
	    #Logger->log(Dumper($self->{order}));
	    #Logger->log(Dumper($row));
	    if ((defined($self->{order}->[$pos-1])) and 
                ($car ne $self->{order}->[$pos-1])) { # position changed

	        splice(@{$self->{order}}, $pos-1, 0, $car); # insert
		
		my $last_idx = scalar(@{$self->{order}})-1;
		for (my $idx = $last_idx; $idx >= 0; $idx--) {
		    #Logger->log("looking at idx: $idx val: ".$self->{order}->[$idx]);
		    if (($car eq $self->{order}->[$idx]) and
			($pos-1 != $idx)) {
			splice(@{$self->{order}}, $idx, 1);
		    }
		}
	    } elsif (!defined($self->{order}->[$pos-1])) {   # it is first time so add car
		Logger->log("adding car: ".Dumper($row)."\n");
	        $self->{order}->[$pos-1] = $car;
            }

	    $self->{field}{$car}{last_lap} = 
		             RaceControl::Utils::time_to_dec($row->[4]);
	    $self->{field}{$car}{laps} = $laps;
            #print "order: ".Dumper($self->{order})."\n";
	} elsif ($rec eq '$H') {  # order by time
	    $self->{field}{$row->[2]}{bl_num}   = $row->[3];
	    $self->{field}{$row->[2]}{best_lap} = 
		              RaceControl::Utils::time_to_dec($row->[4]);
	} elsif ($rec eq '$F') { # time ticker and flag info
	    my $flag = $row->[5]; 
	    $flag =~ s/\s+$//;
            $session{flag} = $flag;
        } elsif ($rec eq '$B') {
	    $session{event} = $row->[2];
        }
    }

    # create %session from tracked info
    my $cnt = 0;
    foreach my $car (@{$self->{order}}) {
	
	$session{positions}[$cnt]{car} = $car;
	if (($car) or ($car eq '0')){ # there was a time when there was a $G missing for a session.   Also, handle car numbe "0"
	    $session{positions}[$cnt]{id}  = $car;
        }
	$session{positions}[$cnt]{position} = $cnt+1;
	$session{positions}[$cnt]{driver}   = $self->{field}{$car}{driver};
	$session{positions}[$cnt]{class}    = $self->{field}{$car}{class};
        $session{positions}[$cnt]{last_lap} = $self->{field}{$car}{last_lap};
	$session{positions}[$cnt]{best_lap} = $self->{field}{$car}{best_lap};
	$session{positions}[$cnt]{bl_num}   = $self->{field}{$car}{bl_num};
	$session{positions}[$cnt]{status}   = 'Run';  # maybe I will find this

        $cnt++;
    }

    # hardcode some stuff for now
    $session{control_message} = '';
#    $session{flag}            = 'Checkered';
#    $session{event}           = 'Test Event';

    #Logger->log('session: '.Dumper(%session));

    return %session;
}
