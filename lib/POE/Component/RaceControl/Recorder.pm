package POE::Component::Recorder;

use strict;
use warnings;
use POE;
use File::Temp qw/ tempfile /;
use Data::Compare;
use File::Path qw(make_path);

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
			     record   => 'record',
			     cease    => 'cease',
			     run_command => 'run_command',
			     got_child_stdout => 'on_child_stdout',
		             got_child_stderr => 'on_child_stderr',
			     got_record_close => 'on_record_close',
			     got_encode_close => 'on_encode_close',
			     got_finalize_close => 'on_finalize_close',
			     got_child_signal => 'on_child_signal',
			     recording => 'recording',
			     processing => 'processing',
			     finalizing => 'finalizing',
			     stopped => 'stopped',
			     info_as_string  => 'info_as_string',

	                   },
                           ],
    )->ID();
    return $self;
}

sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    Logger->log('Starting Recorder');

    $kernel->alias_set( $self->{alias} ) if $self->{alias};

    $self->{info} = ();
    $self->{temp_name} = '';

}

sub _stop {

   print "Stopping Recorder\n";

   #print Dumper($_[HEAP]{children_by_wid});
   #$_[HEAP]{children_by_pid}{$child->PID}->kill();
   #print Dumper($_[HEAP]{children_by_pid});
   foreach (keys %{$_[HEAP]{children_by_wid}}) {
       #print Dumper();
       print "About to kill recorder wheel: $_\n";
       $_[HEAP]{children_by_wid}{$_}->kill();
   }
   #my @keys = keys %{$_[HEAP]{children_by_wid}};
   #    print "keys: @keys\n";
   
   #Logger->log('Stopping Recorder');   # logger is destroyed at this point
}


sub on_child_stdout {
    my ($stdout_line, $wheel_id) = @_[ARG0, ARG1];
    my $child = $_[HEAP]{children_by_wid}{$wheel_id};
    Logger->log("pid ", $child->PID, " STDOUT: $stdout_line");
}


sub on_child_stderr {
    my ($kernel, $stderr_line, $wheel_id) = @_[KERNEL, ARG0, ARG1];
    my $child = $_[HEAP]{children_by_wid}{$wheel_id};

    if (defined $child) {
      #Logger->log("Child: ".Dumper($child));
      Logger->log("pid ", $child->PID, " STDERR: $stderr_line");
      $kernel->post( 'ui', 'recording_error', "Error: $stderr_line" );

      return;
    }

}

sub on_record_close {
    my $wheel_id = $_[ARG0];
    my $child = delete $_[HEAP]{children_by_wid}{$wheel_id};

    Logger->log('Record program has closed');


    # May have been reaped by on_child_signal().
    unless (defined $child) {
      print "wid $wheel_id closed all pipes.\n";
      return;
    }

    print "pid ", $child->PID, " closed all pipes.\n";
    delete $_[HEAP]{children_by_pid}{$child->PID};
}


sub on_encode_close {
    my ($kernel, $heap, $session, $self) = @_[ KERNEL, HEAP, SESSION, OBJECT ];

    my $wheel_id = $_[ARG0];
    my $child = delete $heap->{children_by_wid}{$wheel_id};

    Logger->log('Encode program has closed');

    # remove temp wave file as we are flac from here

    #Logger->log('DEBUG: Not removing temp file');
    unlink $self->{temp_name} or 
             Logger->Log("Could not unlink $self->{temp_name}: $!");

    # start tag command.

    # see race_gui around line 2246 for another way to do date/time stuff
    my $year = (localtime)[5] + 1900;
    my $date = sprintf('%4d/%02d/%02d',
    		           (localtime)[5] + 1900,
    		           (localtime)[4],
    		           (localtime)[3]);

    my $location   = $self->{config}{recorder}{artist};
    my $genre      = $self->{config}{recorder}{genre};

    my $series     = $self->{info}->{Series};
    my $title      = $kernel->call($session, 'info_as_string');


    my @cmd_and_args = (
        '/usr/bin/metaflac',
	"--set-tag=YEAR=$year",   # some mp3 programs only do this
	"--set-tag=DATE=$date",
	"--set-tag=GENRE=$genre",
	"--set-tag=ARTIST=$location",
	"--set-tag=ALBUM=$series",
	"--set-tag=TITLE=$title",
	# add some non-standard tags to save meta data
	"--set-tag=CORNER=$self->{info}->{Corner}",
	"--set-tag=SIDE=$self->{info}->{Side}",
        $self->{file_name},
    );

    $kernel->yield('run_command', 'finalize', \@cmd_and_args);

    $kernel->yield('finalizing');

    # May have been reaped by on_child_signal().
    unless (defined $child) {
      print "wid $wheel_id closed all pipes.\n";
      return;
    }

    print "pid ", $child->PID, " closed all pipes.\n";
    delete $_[HEAP]{children_by_pid}{$child->PID};
}

sub on_finalize_close {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    $kernel->yield('stopped');
}


sub on_child_signal {
    print "pid $_[ARG1] exited with status $_[ARG2].\n";
    my $child = delete $_[HEAP]{children_by_pid}{$_[ARG1]};

    # May have been reaped by on_child_close().
    return unless defined $child;

    delete $_[HEAP]{children_by_wid}{$child->ID};
}


sub record {
    my ($kernel, $self, $session, $args) = @_[ KERNEL, OBJECT, SESSION, ARG0 ];

    #my $rate   = $self->{config}{info_gatherer}{rate};


    if ( (!defined($args->{Corner})) or 
         (!defined($args->{Side}))   or
         (!defined($args->{Series}))   or
         (!defined($args->{Event})) ) {
        return;  # user selected record button but did not provide info
    }
	
    #Logger->log(Dumper($args));
    #Logger->log(Dumper($self->{info}));

    # see race_gui around line 2246 for another way to do date/time stuff
    my $year = (localtime)[5] + 1900;

    my $location   = $self->{config}{recorder}{artist};
    my $genre      = $self->{config}{recorder}{genre};

    my $series     = $args->{Series};

    # /Racing/Road America/2011/ALMS
    $self->{target_dir} = "/library/audio/$genre/$location/$year/$series";

    my $name = $kernel->call($session, 'info_as_string', $args);

    $self->{file_name} = "$self->{target_dir}/$name.flac";

    #if (Compare($args, $self->{info})) { # user did not change what to record
    #    $kernel->post( 'ui', 'recording_idle', 'Abort! Recording information did not change' );
    #	return;
    #}

    if (-e $self->{file_name}) {
        $kernel->post( 'ui', 'recording_idle', 'Abort! File already exists' );
	return;
    }

    $self->{info} = $args;

    Logger->log("Starting Record: $name");

    my $fh = File::Temp->new();
    $self->{temp_name} = $fh->filename.'.wav';

    Logger->log("Using temp file: $self->{temp_name}");

    my @cmd_and_args = ('/usr/bin/arecord', 
                            '-f', 'cd', 
			    '-D', 'hw:1,0',
                            $self->{temp_name}
                         );

    $kernel->yield('run_command', 'record', \@cmd_and_args);

    $kernel->yield('recording');
}

sub run_command {
    my ($kernel, $heap, $function, $cmd) 
                                   = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    Logger->log("function: $function");
    my $child = POE::Wheel::Run->new(
      Program => $cmd,
      StdoutEvent  => 'got_child_stdout',
      StderrEvent  => 'got_child_stderr',
      CloseEvent   => "got_${function}_close",
    );

    $kernel->sig_child($child->PID, "got_child_signal");

    # Wheel events include the wheel's ID.
    $heap->{children_by_wid}{$child->ID} = $child;

    # Signal events include the process ID.
    $heap->{children_by_pid}{$child->PID} = $child;

    # Non-Wheel events take action based on function being performed
    $heap->{children_by_function}{$function} = $child;

    print(
      "Child pid ", $child->PID,
      " started as wheel ", $child->ID, 
      " command: ",Dumper($cmd),".\n"
    );
}

sub cease {
    my ($kernel, $heap, $self, $session, $args) = @_[ KERNEL, HEAP, OBJECT, SESSION, ARG0 ];

    Logger->log("Asked to stop recording");

    if (!-e $self->{temp_name}) {
	Logger->log("Asked to remove temp file $self->{temp_name} but it does not exist");
	$kernel->yield('stopped');
	return;
    }

    # Stop recording command instance

    $heap->{children_by_function}{record}->kill();

    # convert to flac, rename file, fade in/out.

    make_path($self->{target_dir});

    # sox f1-1.wav out.flac fade 5 0 5
    # check out -G option
    # this seems to work:
    #  sox --norm=-0.01 /tmp/orig_with_clipping.wav Cough\ to\ make\ it\ clip\ Corner\ 4\ Inside_with_norm-.01_option.flac
    my @cmd_and_args = ('/usr/bin/sox',
			#'--norm=0.01',#doesn't seem to do anyhing at this point
			$self->{temp_name},
                        $self->{file_name},
			'fade',
			'1',
			'0',
			'1'
	                );

    $kernel->yield('run_command', 'encode', \@cmd_and_args);

    $kernel->yield('processing');
    #$kernel->yield('stopped');

}


sub recording {
    my ($kernel, $self, $session) = @_[ KERNEL, OBJECT, SESSION ];

    Logger->log('Now recording');

    my $info  = $kernel->call($session, 'info_as_string');
    $kernel->post( 'ui', 'recording_active', "Recording: $info" );
}

sub processing {
    my ($kernel, $self, $session) = @_[ KERNEL, OBJECT, SESSION ];

    Logger->log('Now processing');

    my $info  = $kernel->call($session, 'info_as_string');
    $kernel->post( 'ui', 'recording_processing', "Processing: $info" );
}

sub finalizing {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    Logger->log('Now finalizing');
    
    $kernel->post( 'ui', 'recording_finalizing', 'Recording: Finalizing' );
}

sub stopped {
    my ($kernel, $self) = @_[ KERNEL, OBJECT ];

    Logger->log('Recording stopped');

    $kernel->post( 'ui', 'recording_idle', 'Recording: Idle' );
}

sub info_as_string {
    my ($self, $info) = @_[ OBJECT, ARG0 ];

    if (!$info) {
	$info = $self->{info}
    }

    # return string to be used as flac file name
    return sprintf('%s %s %s', 
	                                $info->{Event},
	                                $info->{Corner}, 
                                        $info->{Side}
                  );
}



1;
