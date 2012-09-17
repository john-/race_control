package POE::Component::Announcers;

use strict;
use warnings;
use POE;

use Data::Dumper;

sub spawn {
    my $package = shift;
    my %opts = @_;
    $opts{lc $_} = delete $opts{$_} for keys %opts;
    
#    $opts{utterance_count} = 0;  # used to throttle the utterances

    my $self = bless \%opts, $package;

    $self->{session_id} = POE::Session->create (
	  object_states => [
		  $self => { _start     => '_start',
			     _stop      => '_stop',
			     notice => 'notice',
			     say    => 'say',
			     blab   => 'blab', # speak no matter what
			     quiet => 'mode',
			     talk => 'mode',
			     reset_throttling => 'reset_throttling',
			     #session_refresh => 'session_refresh',
			   },
	  ],
    )->ID();
    return $self;
}

sub _start {
    my ($heap, $kernel, $self) = @_[ HEAP, KERNEL, OBJECT ];

    #$heap->{config} = { $conf->getall };

    $kernel->alias_set( $self->{alias} ) if $self->{alias};

    $heap->{utterance_count} = 0;  # used to throttle the utterances
    $heap->{mode} = 1; # start out talking

    my $default_voice = $self->{config}{race_gui}{booth}{default_voice};

    my $speech = IO::File->new("|/usr/bin/aoss /usr/local/bin/swift -n $default_voice -f -");
#    my $speech = IO::File->new("|/usr/local/bin/swift -n Diane -f - -o - | /usr/bin/aplay");
    if (defined $speech) { $speech->autoflush; }

    $heap->{out} = $speech || undef;

    $kernel->yield( 'reset_throttling' );
}

sub _stop {
    print "shutting down the announcing booth\n";
    $_[KERNEL]->yield( 'say', ['good bye'] );
}

sub notice {
    my ($self, $kernel, $car_ref) = @_[ OBJECT, KERNEL, ARG0 ];

    my %car = %$car_ref;

    my %utts = (  position_improve => 
                   {  speaker => 'Diane',
                      phrase => '$car{driver} P$car{position}'
		   },
                  status_pit =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} pitted'
		   },
                  status_fin =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} finished'
		   },
                  status_ret =>
	           {  speaker => 'Diane',
                      phrase => '$car{driver} retired'
		   },
                  driver =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} in car $car{car}'
		   },
                  best_lap_overall =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best lap $car{last_lap_words}'
		   },
                  best_lap_p1 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best P1 lap $car{last_lap_words}'
		   },
                  best_lap_p2 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best P2 lap $car{last_lap_words}'
		   },
                  best_lap_gt1 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best GT1 lap $car{last_lap_words}'
		   },
                  best_lap_gt2 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best GT2 lap $car{last_lap_words}'
		   },
                  best_speed_overall =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best speed $car{best_speed}'
		   },
                  best_speed_p1 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best P1 speed $car{best_speed}'
		   },
                  best_speed_p2 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best P2 speed $car{best_speed}'
		   },
                  best_speed_gt1 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best GT1 speed $car{best_speed}'
		   },
                  best_speed_gt2 =>
	           {  speaker => 'Lawrence',
                      phrase => '$car{driver} best GT2 speed $car{best_speed}'
		   },
	       );


    if (@{$car{changes}} == 0) { 
	Logger->log({level => 'warning', message => 'Announcer was asked to notice nothing happening'});
    }

    foreach (@{$car{changes}}) {
	if (defined $utts{$_}) {
	    my $utterance;
	    if ($utts{$_}{speaker} eq 
                      $self->{config}{race_gui}{booth}{default_voice}) {
	        $utterance = "$utts{$_}{phrase}\n";
            } else {
		$utterance = 
              "<voice name=\"$utts{$_}{speaker}\">$utts{$_}{phrase}</voice>\n";
	    }
	    $utterance =~ s/\$car\{(\w+)\}/$car{$1}/g;
	    #$utterance =~ s/(\$car\{\w+\})/$1/gee;
	    $kernel->yield( 'say' => $utterance );
        }

    }




}

sub say {
    my ($heap, $self, $words) = @_[ HEAP, OBJECT, ARG0 ];

    my $fh = $heap->{out};

    if (defined $fh and $heap->{mode}) {
	if ($heap->{utterance_count} <= 4) {
            print $fh "$words\n\n";
	    $heap->{utterance_count}++;
	    Logger->log("Announcer says: $words");
	} else {
	    Logger->log({level => 'warning', message => "Announcer throttled!: $words"});
        }
    } else {
        Logger->log("Announcer says: $words");
    }

}
sub blab {
    my ($heap, $self, $car_ref) = @_[ HEAP, OBJECT, ARG0 ];

    my %car = %$car_ref;

    my $fh = $heap->{out};

    my $time = $car{best_lap};
    $car{last_lap_words} = 
                           sprintf("%d minute %.2f", 
			   ($time/60)%60, $time%60 + $time-int($time));


    my $words = "<voice name=\"Lawrence\">$car{driver} best lap $car{last_lap_words}";

    $words =~ s/\$car\{(\w+)\}/$car{$1}/g;

    if (defined $fh and $heap->{mode}) {

        print $fh "$words\n\n";

    }

    Logger->log("Announcer says: $words");

}

#sub session_refresh {
#    $_[HEAP]->{utterance_count} = 0;
#}

sub reset_throttling {

    #Logger->log('resetting throttler');
    $_[HEAP]->{utterance_count} = 0;

    $_[KERNEL]->delay('reset_throttling' => 30);
}

sub mode {
    my ($heap, $state) = @_[ HEAP, STATE ];

    if ($state eq 'quiet') {
	$heap->{mode} = 0;
	Logger->log({level => 'info', message => 'told to shut up'});
    } else {
	$heap->{mode} = 1;
	Logger->log({level => 'info', message => 'told to talk'});
    }

}

1;
