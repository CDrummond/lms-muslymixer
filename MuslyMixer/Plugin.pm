package Plugins::MuslyMixer::Plugin;

#
# Musly 'Dont Stop The Music' mixer.
#
# (c) Craig Drummond, 2020
#
# Licence: GPL v3
#

use strict;

use Scalar::Util qw(blessed);
use LWP::UserAgent;
use JSON::XS::VersionOneAndTwo;
use File::Basename;
use File::Slurp;

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Prefs;

if ( main::WEBUI ) {
    require Plugins::MuslyMixer::Settings;
}

use Plugins::MuslyMixer::Settings;

my $initialized = 0;
my @genreSets = ();
my $NUM_TRACKS_TO_USE = 5;
my $NUM_SEED_TRACKS = 5;
my $MAX_PREVIOUS_TRACKS = 100;

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.muslymixer',
    'defaultLevel' => 'ERROR',
    'logGroups'    => 'SCANNER',
});

my $prefs = preferences('plugin.muslymixer');

sub shutdownPlugin {
    $initialized = 0;
}

sub initPlugin {
    my $class = shift;

    return 1 if $initialized;

    $prefs->init({
        filter_genres   => 1,
        filter_xmas     => 1,
        exclude_artists => '',
        exclude_albums  => '',
        port            => 11000,
        min_duration    => 0,
        max_duration    => 0
    });

    if ( main::WEBUI ) {
        Plugins::MuslyMixer::Settings->new;
    }

    $initialized = 1;
    return $initialized;
}

sub postinitPlugin {
    my $class = shift;

    # if user has the Don't Stop The Music plugin enabled, register ourselves
    if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin') ) {
        require Slim::Plugin::DontStopTheMusic::Plugin;
        Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('MUSLYMIXER_MIX', sub {
            my ($client, $cb) = @_;

            my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $NUM_SEED_TRACKS);
            my $tracks = [];

            # don't seed from radio stations - only do if we're playing from some track based source
            # Get list of valid seeds...
            if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
                my @seedIds = ();
                my @seedsToUse = ();
                foreach my $seedTrack (@$seedTracks) {
                    my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
                    if ($trackObj) {
                        main::DEBUGLOG && $log->debug("Seed " . $trackObj->path . " id:" . $seedTrack->{id});
                        push @seedsToUse, $trackObj;
                        push @seedIds, $seedTrack->{id};
                    }
                }

                if (scalar @seedsToUse > 0) {
                    my $previousTracks = _getPreviousTracks($client, \@seedIds, $MAX_PREVIOUS_TRACKS);
                    main::DEBUGLOG && $log->debug("Num tracks to previous: " . ($previousTracks ? scalar(@$previousTracks) : 0));

                    my $jsonData = _getMixData(\@seedsToUse, $previousTracks ? \@$previousTracks : undef);
                    my $port = $prefs->get('port') || 11000;
                    my $url = "http://localhost:$port/api/similar";
                    Slim::Networking::SimpleAsyncHTTP->new(
                        sub {
                            my $response = shift;
                            main::DEBUGLOG && $log->debug("Received Musly response");

                            my @songs = split(/\n/, $response->content);
                            my $count = scalar @songs;
                            my $tracks = ();

                            for (my $j = 0; $j < $count; $j++) {
                                # Bug 4281 - need to convert from UTF-8 on Windows.
                                if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
                                    $songs[$j] = Win32::GetANSIPathName($songs[$j]);
                                }

                                if ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j]) || index($songs[$j], 'file:///')==0) {
                                    push @$tracks, Slim::Utils::Misc::fileURLFromPath($songs[$j]);
                                } else {
                                    $log->error('Musly attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
                                }
                            }

                            main::DEBUGLOG && $log->debug("Num tracks to use:" . scalar(@$tracks));
                            foreach my $track (@$tracks) {
                                main::DEBUGLOG && $log->debug("..." . $track);
                            }
                            $cb->($client, $tracks);
                        },
                        sub {
                            my $response = shift;
                            my $error  = $response->error;
                            main::DEBUGLOG && $log->debug("Failed to fetch URL: $error");
                            $cb->($client, []);
                        }
                    )->post($url, 'Content-Type' => 'application/json;charset=utf-8', $jsonData);
                }
            }
        });
    }
}

sub prefName {
    my $class = shift;
    return lc($class->title);
}

sub title {
    my $class = shift;
    return 'MuslyMIXER';
}

sub _getPreviousTracks {
    my ($client, $seeIds, $count) = @_;
    my @seeds = ref $seeIds ? @$seeIds : ($seeIds);
    my %seedsHash = map { $_ => 1 } @seeds;
    return unless $client;

    $client = $client->master;
    my ($trackId, $artist, $title, $duration, $mbid, $artist_mbid, $tracks);

    foreach (reverse(@{ Slim::Player::Playlist::playList($client) })) {
        ($artist, $title, $duration, $trackId, $mbid, $artist_mbid) = Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $_);
        next unless defined $artist && defined $title && !exists($seedsHash{$trackId});
        my ($trackObj) = Slim::Schema->find('Track', $trackId);
        if ($trackObj) {
            push @$tracks, $trackObj;
            if (scalar @$tracks >= $count) {
                return $tracks;
            }
        }
    }
    return $tracks;
}

sub _getMixData {
    my $seedTracks = shift;
    my $previousTracks = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @previous = ref $previousTracks ? @$previousTracks : ($previousTracks);
    my @mix = ();
    my @track_paths = ();
    my @previous_paths = ();
    my @exclude_artists = ();
    my @exclude_albums = ();

    foreach my $track (@tracks) {
        push @track_paths, $track->url;
    }

    if ($previousTracks and scalar @previous > 0) {
        @previous = reverse(@previous);
        foreach my $track (@previous) {
            push @previous_paths, $track->url;
        }
    }

    my $exclude = $prefs->get('exclude_artists');
    if ($exclude) {
        my @exclude_list = split(/,/, $exclude);
        foreach my $ex (@exclude_list) {
            push @exclude_artists, $ex;
        }
    }

    $exclude = $prefs->get('exclude_albums');
    if ($exclude) {
        my @exclude_list = split(/,/, $exclude);
        foreach my $ex (@exclude_list) {
            push @exclude_albums, $ex;
        }
    }

    my $http = LWP::UserAgent->new;
    my $jsonData = to_json({
                        count         => $NUM_TRACKS_TO_USE,
                        format        => 'text',
                        filtergenre   => $prefs->get('filter_genres') || 0,
                        filterxmas    => $prefs->get('filter_xmas') || 0,
                        min           => $prefs->get('min_duration') || 0,
                        max           => $prefs->get('max_duration') || 0,
                        track         => [@track_paths],
                        previous      => [@previous_paths],
                        excludeartist => [@exclude_artists],
                        excludealbum  => [@exclude_albums]
                    });
    $http->timeout($prefs->get('timeout') || 5);
    main::DEBUGLOG && $log->debug("Request $jsonData");
    return $jsonData;
}

1;

__END__
