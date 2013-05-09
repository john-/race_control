package POE::Component::Session;

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use RaceControl::Utils;
use RaceControl::Car;

use POE;
use Module::Load;

use HTTP::Request::Common qw(GET POST);
use POE::Component::Client::HTTP;
use Tie::IxHash;
use Data::Compare;

use Switch 'Perl6';

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
			     set_series       => 'set_series',
			     get_series       => 'get_series',
			     get_series_list  => 'get_series_list',
			     refresh    => 'refresh',
			     refresh_rate => 'refresh_rate',
			     reset      => 'reset',
			     stats_reset => 'stats_reset',
			     proxy      => 'proxy',
			     kickit     => 'kickit',
			     file_request => 'file_request',
			     got_response => 'got_response',
			     tell_me_about_car_at_pos => 'car_info',
			     crawler    => 'crawler',
			     crawl_response => 'crawl_response',
			     request_series_change => 'request_series_change',
			     get_car_picture => 'car_image',
			     create_user_agent => 'create_user_agent',
			     # TODO: Iterate through leaderboards (during
			     #       weekends) and look for activity
			     #autoloader => 'autoloader',
			   },
	  ],
    )->ID();
    return $self;
}

sub _start {
    my ($kernel, $self, $heap) = @_[KERNEL, OBJECT, HEAP];

    $kernel->alias_set( $self->{alias} ) if $self->{alias};

    Logger->log('Loading loaders based on config');

    my %series_info = %{$self->{config}{session}{series}};

    my %to_load;
    foreach (keys %series_info) {

	my $loader = $series_info{$_}{loader};
        Logger->log( {level => 'debug', message => "should load: $_"});

	if (exists $series_info{$_}{disable} and lc($series_info{$_}{disable}) eq 'yes') {
	    Logger->log( {level=> 'debug', message => "skipping $_ per config"});
	    next;
        }

	$to_load{$loader} = 'yes, load me';

    }

    foreach (keys %to_load) {
	Logger->log("loading: $_");
	my $module = "RaceControl::$_";
	load $module;
    }

    Logger->log('Loaded loaders complete');


    $self->{rate} = 30;  # default rate
    $self->{session_id} = 0; # unique across this PID only.Used for file naming
    Logger->log(" session id: $self->{session_id}");

#    $self->{loader} = undef;

    _init($self);
}

sub _init {
    my ($self) = @_;


    $self->{flag} = '';
    $self->{race_message} = '';
    $self->{control_message} = '';
    $self->{time} = '';
    $self->{remaining} = '';
    $self->{event} = '';
    $self->{_cars} = {};
    $self->{best_lap} = {};
    $self->{best_speed} = {};

    if (defined $self->{series}) {
        $self->{last_timing}{$self->{series}}{counter} = 0;
    }

    Logger->log("session structures inititalized");

}

sub get_series {
    
    return $_[OBJECT]->{series};
}

sub get_series_list {
    my %series_list = %{$_[OBJECT]->{config}{session}{series}};

    for (keys %series_list) {
	if (exists $series_list{$_}{disable} and lc($series_list{$_}{disable}) eq 'yes') {

	    delete $series_list{$_};
        }
    }
    
    return keys %series_list;
}

sub set_series {
    my ($kernel, $self, $session, $series) = @_[ KERNEL, OBJECT, SESSION, ARG0 ];

    #Logger->log({level => 'info',message => "setting the series to: $series"});

    #$kernel->post( 'ui', 'change_series', $series );
    if ($series eq 'Auto') {
        $kernel->delay( 'kickit' => undef ); 
	$kernel->yield('crawler');
	return;
    }

    $kernel->delay( 'crawler' => undef ); 

    if ( ($series eq 'Off') or 
	( !%{$self->{config}{session}{series}{$series}}) ) {

        $kernel->delay( 'kickit' => undef ); 

	return;
    }

    my %series_info = %{$self->{config}{session}{series}{$series}};

    if (exists($series_info{streaming})) {
        $self->{streaming} = lc($series_info{streaming})
    } else {
	$self->{streaming} = 'no'
    }
    $kernel->call($session => 'create_user_agent' => $self->{streaming});

    #Logger->log("series info: ".Dumper(%series_info));
    
    ++$self->{session_id};

    $self->{series} = $series;

    $self->{retreival} = $self->{config}{race_gui}{loader}{method};

    # for 'http' method
    $self->{url} = $series_info{url};    

    $self->{basedir} = RaceControl::Utils::abs_path($self->{config}{race_gui}{loader}{data_dir}) . '/';

    # for 'file' method
    $self->{file_root} = $self->{config}{race_gui}{loader}{file_root};
    $self->{file_num} = $self->{config}{race_gui}{loader}{file_num};

    #Logger->log("about to create $series_info{loader}");

    $self->{loader} = $series_info{loader}->new(Series => $series,
                                                Config => $self->{config});

    my $session_dump = $self->{basedir} . 'dumps/' . $series . '-' . $$ . '-' . $self->{session_id} . '.dump';
    Logger->log("dump file: $session_dump");
    # store the pieces and parts of the above file name in $self and ref in Car obj for file creation
    # I guess create file here and store reference so it is accesible by Car obj
    # call a class method?   Car.init_dump_file
    Car::init($session_dump);

    $kernel->yield( 'reset' );
    #$kernel->post( 'ui', 'event_msg_change', 'Event has changed' );
}

sub _stop {

    print "stopping the session session\n";
}

sub create_user_agent {
    my ($kernel, $self, $streaming) = @_[ KERNEL, OBJECT, ARG0 ];

    my $user   = $self->{config}{session}{timeout};

    my %opts = (
	  Alias => 'ua',
	  Timeout => 15,
	  Agent => $self->{config}{session}{useragent},
	  # need to research FollowRedirects more.  ALMS stopped working
	  # with default so set it to 2 on a whim
	  #FollowRedirects => 2,
	  #Proxy => "http://localhost:8080",
    );
    if ((defined $streaming) and ($streaming eq 'yes')) {
        $opts{Streaming} = 80;
    }

    Logger->log({level => 'debug', message => "opts:".Dumper(%opts)});

    $kernel->call('ua' => 'shutdown');  # I am not sure about this
    $self->{ua} = POE::Component::Client::HTTP->spawn( %opts )
}

sub kickit {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    given ($self->{retreival}) {
	when /http/ { 
     	               Logger->log('requesting web page...');

                       $self->{cur_request} = HTTP::Request->new('GET', $self->{url});
                       $kernel->post( ua => request => got_response 
                                                => $self->{cur_request} );
		       Logger->log("url: $self->{url}");
		    }
	when /file/ {  $kernel->yield( 'file_request' ) }
    }
        
}

sub file_request {
    my ( $kernel, $self ) = @_[KERNEL, OBJECT];
    Logger->log('file load was requested');

    my $file = $self->_file_name();

    if (! -f $file ) { 
	Logger->log({level => 'critical', message => "file $file does not exist.  Maybe end of race?"});
	die;
    }

    Logger->log("file: $file");

    my $fh = IO::File->new("< $file");

    my $contents;

    {
        local $/ = undef;
	$contents = <$fh>;
    }

    $fh->close;




    $kernel->yield( 'refresh', $contents );
}

sub got_response {
    my ( $kernel, $heap, $response_packet, $self ) = @_[ KERNEL, HEAP, ARG1, OBJECT ];
    #my ($res, $data) = @{$_[ARG1]};

    Logger->log('...received web page');

    delete $self->{cur_request};

    #my $http_response = $response_packet->[0];

    #my $response_string = $http_response->as_string();
 
    # write out file in case a problem needs to be reproduced
    my $file_name = $self->{basedir} . 'leaderboards/' . $self->{series};

    my $http_response;
    my $response_string;
    my $debug_file;
    if ($self->{streaming} eq 'yes') {
        #$http_response = $response_packet->[1];
        ($http_response, $response_string) = @$response_packet;
	$file_name .= '-' . $$ . '-' . $self->{session_id} . '.html';
	if (!-e $file_name) {
            Logger->log("file: $file_name");
	}
        $debug_file = IO::File->new(">> $file_name");
	
    } else {
        $http_response = $response_packet->[0];
        $response_string = $http_response->as_string();
	$file_name .= '-' . $$ . '-' . $self->{session_id} . '-' .
	    $self->{file_num} . '.html';
        Logger->log("file: $file_name");
	$debug_file = IO::File->new("> $file_name");
    }


    #Logger->log({level => 'info', message => "debug file: $file_name"});

    
    # TODO:  when streaming it looks like at "end" $response_string can be empty
    #        if that is correct, then don't try and print it.
    print $debug_file $response_string;
    #Logger->log("response_string: $response_string");
    $debug_file->close;

    $self->{file_num}++;

    if ($http_response->is_success) {
        $kernel->post( 'ui', 'session_update', 'success' );
	$kernel->yield( 'refresh', $response_string );
    } else { 
	Logger->log('Error downloading page.  Skipping refresh');
	# if not a server error than assume connectivity lost
	# yes, this is weak...probably need to add in other codes or redesign
	if ($http_response->code() ne 500) {
            $kernel->post( 'ui', 'session_update', 'fail' );
        }
	#$kernel->delay( 'kickit' => $self->{rate} );
	# try again soon
	$kernel->delay( 'kickit' => 3 );
    }
}

sub refresh {
    my ($kernel, $self, $sender, $raw_session) = @_[ KERNEL, OBJECT, SENDER, ARG0 ];
    
    #Logger->log("raw_session: $raw_session");

    my %session = $self->{loader}->get_state( $raw_session );
    #Logger->log(Dumper(%session));
    #Logger->log(Dumper($self->{loader}));

    #Logger->log("SKIPPING REFRESH!");
    #return;


    # if nothing there skip this iteration
    # For example, if loader gets error free response from
    # a leaderboard but there is invalid data in request.
    if (!%session) { 
        $kernel->delay( 'kickit' => $self->{rate} );
	return;
     }


    # look for changing session.  Reset to Auto mode if it isn't changing
    
    my $series = $self->{series};
    if ( !Compare(\%session, $self->{last_timing}{$series}{content}) ) {
        Logger->log("content has changed for $series (in refresh)");
        $self->{last_timing}{$series}{counter} = 0;
	#Logger->log("ORIG: ".Dumper(%{$self->{last_timing}{$series}{content}}));
	#Logger->log("NEW: ".Dumper(%session)); 

    } else {
        ++$self->{last_timing}{$series}{counter};
	Logger->log("no change for $series (in refresh)  count: $self->{last_timing}{$series}{counter}");
    }

    # store for next pass through
    %{$self->{last_timing}{$series}{content}} = %session;

    my $time_idle = $self->{last_timing}{$series}{counter} * $self->{rate};
    my $timeout   = $self->{config}{session}{timeout};
    if (($time_idle > $timeout) and ($self->{streaming} eq 'no')) {
	Logger->log('going into Auto mode');
	#$self->{last_timing}{$series}{counter} = 0;
        #$kernel->yield( 'set_series' => 'Auto' );
        $kernel->post( 'ui', 'change_series', 'Auto' );
	return;
    }

    # non-car updates
    
    # Note: if you add a tracked_bit, add to _init
    my %tracked_bits = ( flag => [ '<voice name="Diane">%s flag</voice>', 'flag_change' ],
	      control_message => [ '%s', 'ctrl_msg_change' ],
		 race_message => [ '%s', 'race_msg_change' ],
			 time => [ '',   'time_msg_change' ],
		    remaining => [ '',   'remaining_msg_change' ],
		        event => [ '%s', 'event_msg_change' ], );
    foreach my $bit (keys %tracked_bits) {
        if (defined $session{$bit} and $self->{$bit} ne $session{$bit}) {
	    if ($session{$bit} ne '') {
		if ($tracked_bits{$bit}[0] ne '') {
                    $kernel->post( 'booth' => 'say' => 
                        (sprintf($tracked_bits{$bit}[0], $session{$bit})));
	        }
		if (defined $tracked_bits{$bit}[1]) {
		    $kernel->post( 'ui' => $tracked_bits{$bit}[1] => $session{$bit} );
		}

	    }

	    $self->{$bit} = $session{$bit};
        }
    }


    # car updates

    foreach (@{$session{positions}}) {

	if (!exists($_->{id})) {
	    next;
	}

        my $id;

	# the check for id = '0' was brute force fix for when
	# car number is 0.  For example: 
        # /library/data/leader_boards/IMSA-3473-1
	# Driver is Donald Pickering
        #Logger->log(Dumper($_));
	if (($_->{id}) or ($_->{id} eq '0')) {
	    $id = $_->{id};
	}

	unless (defined $self->{_cars}->{$id}) { 
	    $self->{_cars}->{$id} = Car->new( Session => $self,
                                               Kernel => $kernel, );
     	};

	$self->{_cars}->{$id}->update($_);

	# store the last N intervals for this car

	# 

	#print "$_->{position} ";
	#foreach my $key (keys %$_) {
	#    print "$key ($_->{$key})  ";
	#}
	#print "\n\n";
	#print "just before update pos: $_->{position} driver: $_->{driver}  car: $_->{car} var car: $car\n";


    }

    if ($self->{streaming} eq 'no') {
        $kernel->delay( 'kickit' => $self->{rate} );
    }
}

sub status {
    my ($msg) = @_;


    Logger->log("Status: $msg");
}

sub refresh_rate {
    my ($kernel, $self, $rate) = @_[ KERNEL, OBJECT, ARG0 ];

    $self->{rate} = $rate;
    Logger->log({level => 'info', message => "Setting refresh rate to $rate"});

    $kernel->yield( 'kickit' );


}
sub reset {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    if (exists($self->{cur_request})) {
        Logger->log('about to cancel main http request');
        Logger->log(Dumper( $self->{cur_request} ));
        $kernel->post( 'ua' => 'cancel' => $self->{cur_request} );
    }

    # cancel any crawler requests

    foreach (keys %{$self->{last_timing}}) {
	if (exists($_{request})) {
            Logger->log("about to cancel crawler request: $_");
	    Logger->log(Dumper($self->{last_timing}{$_}{request}));
            $kernel->post( 'ua' => 'cancel' => $self->{last_timing}{$_}{request} );
	}

    }

    _init($self);

    $kernel->yield( 'kickit' );
    
    #$kernel->post( 'ui' => 'status_msg' => 'Session reset' );


    Logger->log({level => 'warning', message => 'session reset'});

}

sub stats_reset {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    $self->{best_lap} = {};
    $self->{best_speed} = {};

    Logger->log({level => 'warning', message => 'stats cleared'});
}

sub proxy {
    my ($kernel, $self, $proxy) = @_[ KERNEL, OBJECT, ARG0 ];

    $self->{loader}->proxy($proxy);

}

sub crawler {
    my ($kernel, $self, $session) = @_[ KERNEL, OBJECT, SESSION ];

    # check to make sure it is the weekend
    # TODO

    # Create a single ua for crawling multiple urls
    $kernel->call($session => 'create_user_agent');

    # iterate through each series and set and retreive leaderboard
    my %series_info = %{$self->{config}{session}{series}};

    #Logger->log(Dumper(%series_info));

    foreach (keys %series_info) {
	if ((exists $series_info{$_}{disable} and lc($series_info{$_}{disable}) eq 'yes') or
           (exists $series_info{$_}{streaming} and lc($series_info{$_}{streaming}) eq 'yes')) {
	    Logger->log( { level => 'debug', message => "skipping $_ per config (disabled or streaming)" } );
	    next;
        }

        Logger->log("going to crawl: $_");

        $self->{last_timing}{$_}{request}  = HTTP::Request->new('GET', $series_info{$_}{url});
	$kernel->post( ua => request => crawl_response => $self->{last_timing}{$_}{request} => $_ );
    }

    #Logger->log('requesting web page...');
    #$self->{cur_request} = HTTP::Request->new('GET', $self->{url});
    #$kernel->post( ua => request => got_response => $self->{cur_request} );
    #Logger->log("url: $self->{url}");

    $kernel->delay( 'crawler' => 60 );

}

sub crawl_response {
    my ( $kernel, $heap, $request_packet, $response_packet, $self ) = @_[ KERNEL, HEAP, ARG0, ARG1, OBJECT ];

    my $series = $request_packet->[1]; # from the 'request' post
    my $http_response = $response_packet->[0];

    my $content = $http_response->as_string();

    delete $self->{last_timing}{$series}{request};

    Logger->log("...received web page: $series");

    # commented out error/success handling when crawling because
    # is_sucess can fail for multiple reasons not all of them
    # result of lost connectivity.
    #if (!$http_response->is_success) {
    #    $kernel->post( 'ui', 'session_update', 'fail' );
    #    Logger->log("Error downloading page.  Skipping refresh ($series)");
    #return;
    #}

    #$kernel->post( 'ui', 'session_update', 'success' );


    # instantiate a session object
    
    my %series_info = %{$self->{config}{session}{series}{$series}};
    my $loader = $series_info{loader}->new(Series => $series,
	                                   Config => $self->{config});

    # parse the content

    my %session = $loader->get_state( $content );

    #compare to previous time

    if (!defined $self->{last_timing}{$series}{content}) {
	#Logger->log("content is defined for $series");
        # do nothing
    } elsif ( !Compare(\%session, $self->{last_timing}{$series}{content}) ) {
        Logger->log("content has changed for $series");
	#Logger->log("ORIG: ".Dumper($self->{last_timing}{$series}{content}));
	#Logger->log("NEW:  ".Dumper(%session)); 
	# set this series
        #$kernel->yield( 'set_series' => $series );

	# seems like if session was changed too quick then
	# loader object was corrected incorrectly (wrong one created?)
        $kernel->delay( 'request_series_change' => 3 => $series );

    } else {
	Logger->log("no change for $series");
    }

    %{$self->{last_timing}{$series}{content}} = %session;

}

sub request_series_change {
    my ($kernel, $series) = @_[ KERNEL, ARG0 ];
    
    # call out to UI requesting a change in series;
    $kernel->post( 'ui', 'change_series', $series );

}

sub car_info {
    my ($self, $pos) = @_[ OBJECT, ARG0 ];

    foreach my $car (keys %{$self->{_cars}}) {
	if ($pos eq $self->{_cars}->{$car}->{position}) {
#    	    print "pos: $pos driver: $self->{_cars}->{$car}->{driver}\n";
	    $self->{_cars}->{$car}->about;
        }
    }
}

sub car_image {
    my ($self, $pos) = @_[ OBJECT, ARG0 ];

    my $image;

    foreach my $car (keys %{$self->{_cars}}) {
	if ($pos eq $self->{_cars}->{$car}->{position}) {
#    	    print "pos: $pos driver: $self->{_cars}->{$car}->{driver}\n";
	    $image = $self->{_cars}->{$car}->image;
        }
    }


}

sub _file_name {
    my ($self) = @_;

    my $file = $self->{basedir} . $self->{file_root} . 
                                               $self->{file_num} . '.html';

    Logger->log("file in _file_name: $file");

    $self->{file_num}++;

    return $file;
}



1;

