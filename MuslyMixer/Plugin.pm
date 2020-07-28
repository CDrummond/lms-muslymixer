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
my $NUM_TRACKS = 15;
my $NUM_TRACKS_TO_USE = 5;
my $NUM_SEED_TRACKS = 5;
my $IGNORE_LAST_TRACKS = 25;

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
                    my $ignoreTracks = _getTracksToIgnore($client, \@seedIds, $IGNORE_LAST_TRACKS);
                    main::DEBUGLOG && $log->debug("Num tracks to ignore: " . ($ignoreTracks ? scalar(@$ignoreTracks) : 0));

                    my $mix = _getMix(\@seedsToUse, $ignoreTracks ? \@$ignoreTracks : undef);
                    main::idleStreams();
                    if ($mix && scalar @$mix) {
                        push @$tracks, @$mix;
                    }
                }
            }

            # Remove duplicates...
            my $deDupTracks = Slim::Plugin::DontStopTheMusic::Plugin->deDupe($tracks);
            if ( scalar @$deDupTracks < $NUM_TRACKS_TO_USE ) {
                main::DEBUGLOG && $log->debug("Too few tracks after de-dupe, use orig");
                $deDupTracks = $tracks;
            }

            # Shuffle tracks...
            Slim::Player::Playlist::fischer_yates_shuffle($deDupTracks);

            # If we have more than num tracks, then use 1st num...
            if ( scalar @$deDupTracks > $NUM_TRACKS_TO_USE ) {
                $deDupTracks = [ splice(@$deDupTracks, 0, $NUM_TRACKS_TO_USE) ];
            }
            $cb->($client, $deDupTracks);
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

sub _getTracksToIgnore {
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

sub _getMix {
    my $seedTracks = shift;
    my $ignoreTracks = shift;
    my @tracks = ref $seedTracks ? @$seedTracks : ($seedTracks);
    my @ignore = ref $ignoreTracks ? @$ignoreTracks : ($ignoreTracks);
    my @mix = ();
    my @track_paths = ();
    my @ignore_paths = ();
    my @exclude_artists = ();

    foreach my $track (@tracks) {
        push @track_paths, $track->url;
    }

    if ($ignoreTracks and scalar @ignore > 0) {
        @ignore = reverse(@ignore);
        foreach my $track (@ignore) {
            push @ignore_paths, $track->url;
        }
    }

    my $exclude = $prefs->get('exclude_artists');
    if ($exclude) {
        my @excludeList = split(/,/, $exclude);
        foreach my $ex (@excludeList) {
            push @exclude_artists, $ex;
        }
    }

    my $port = $prefs->get('port') || 11000;
    my $url = "http://localhost:$port/api/similar";
    my $http = LWP::UserAgent->new;
    my $jsonData = to_json({
                        count       => $NUM_TRACKS,
                        format      => 'text',
                        filtergenre => $prefs->get('filter_genres') || 0,
                        filterxmas  => $prefs->get('filter_xmas') || 0,
                        min         => $prefs->get('min_duration') || 0,
                        max         => $prefs->get('max_duration') || 0,
                        track       => [@track_paths],
                        ignore      => [@ignore_paths],
                        exclude     => [@exclude_artists]
                    });
    $http->timeout($prefs->get('timeout') || 5);
    main::DEBUGLOG && $log->debug("Request $url - $jsonData");
    my $response = $http->post($url, 'Content-Type' => 'application/json;charset=utf-8', 'Content' => $jsonData);

    if ($response->is_error) {
        $log->warn("Warning: Couldn't get mix: $jsonData");
        main::DEBUGLOG && $log->debug($response->as_string);
        return \@mix;
    }

    my @songs = split(/\n/, $response->content);
    my $count = scalar @songs;

    for (my $j = 0; $j < $count; $j++) {
        # Bug 4281 - need to convert from UTF-8 on Windows.
        if (main::ISWINDOWS && !-e $songs[$j] && -e Win32::GetANSIPathName($songs[$j])) {
            $songs[$j] = Win32::GetANSIPathName($songs[$j]);
        }

        if ( -e $songs[$j] || -e Slim::Utils::Unicode::utf8encode_locale($songs[$j]) || index($songs[$j], 'file:///')==0) {
            push @mix, Slim::Utils::Misc::fileURLFromPath($songs[$j]);
        } else {
            $log->error('Musly attempted to mix in a song at ' . $songs[$j] . ' that can\'t be found at that location');
        }
    }

    return \@mix;
}

1;

__END__
