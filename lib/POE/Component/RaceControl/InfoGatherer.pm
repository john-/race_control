package POE::Component::InfoGatherer;

use strict;
use warnings;
use POE;
use Weather::Underground;

use Data::Dumper;


sub spawn {
    my $package = shift;

    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;

    my $self = bless \%opts, $package;


    $self->{poe_session_id} = POE::Session->create (
	  object_states => [
		  $self => { _start     => '_start',
			     _stop      => '_stop',
			     get_info   => 'get_info',

	                   },
                           ],
    )->ID();
    return $self;
}

sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    Logger->log('Starting InfoGatherer');

    $kernel->alias_set( $self->{alias} ) if $self->{alias};

    #$kernel->yield( 'get_info' );
    $kernel->delay( 'get_info' => 60 );  # initial delay
}

sub _stop {

   Logger->log('Stopping InfoGatherer');
}

sub get_info {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    my $rate   = $self->{config}{info_gatherer}{rate};

    Logger->log('Requesting weather info');

    my $weather = Weather::Underground->new(
        place => $self->{config}{info_gatherer}{place},
        debug => 0,
    )
            || Logger->log("Error, could not create new weather object: $@");

    my $arrayref = $weather->get_weather();
    
    if (! defined $arrayref) { 
        Logger->log("Error, calling get_weather() failed: $@");
        $kernel->delay( 'get_info' => $rate );
        return;
    }

    # asssume there is only one
    my $stats = $arrayref->[0];

    # do transforms
    my $wind_dir = $stats->{wind_direction};
    if ($wind_dir eq uc($wind_dir)) {
	Logger->log("raw wind value: $wind_dir");
	# got a designator like NNW
	$wind_dir =~ s/N/North /g;
	$wind_dir =~ s/S/South /g;
	$wind_dir =~ s/E/East /g;
	$wind_dir =~ s/W/West /g;
	
	$stats->{wind_direction} = $wind_dir;
    }

    # compare to previous values
    my %tracked = %{$self->{config}{info_gatherer}{tracked}};
    foreach (keys %tracked ) {
	#print Dumper($_);
	if (!defined $self->{stats}{$_}) {
	    # first time for this stat so say the stat
	    #Logger->log("Saved for first time: $_ = $stats->{$_}\n");
            $kernel->post( 'ui', 'weather_update', 
			   sprintf($tracked{$_}{say}, $stats->{$_}) );
            $self->{stats}{$_} = $stats->{$_};
	} else {
	    # compare to previous value
	    if ( defined $tracked{$_}{threshold} ) {
		#Logger->log("Threshold set for $_\n");
		if ( abs($stats->{$_} - $self->{stats}{$_}) ge
			 $tracked{$_}{threshold} ) {
		    # threshold is set and delta exceeds it
		    #Logger->log("stat $_ over threshold");
		    $kernel->post( 'ui', 'weather_update', 
			           sprintf($tracked{$_}{say}, $stats->{$_}) );
                    $self->{stats}{$_} = $stats->{$_};
		}
            } elsif ( $stats->{$_} ne $self->{stats}{$_} ) {
		# no threshold set and value has changed
		#Logger->log("stat $_ changed (no threshold set)");
		$kernel->post( 'ui', 'weather_update', 
		               sprintf($tracked{$_}{say}, $stats->{$_}) );
                $self->{stats}{$_} = $stats->{$_};
            }
	}

    }

    $kernel->delay( 'get_info' => $rate );

}


1;
