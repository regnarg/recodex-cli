#!/usr/bin/perl6

use Inline::Perl5;
use WWW::Mechanize:from<Perl5>;
use Term::ReadPassword:from<Perl5>;
use JSON::Fast;

my $token-file = (%*ENV<XDG_CACHE_DIR> // "%*ENV<HOME>/.cache").IO.child("recodex-token");
my $token;
my $root = "https://recodex.mff.cuni.cz/api/v1";
multi to-str(Str $x) { $x }
multi to-str(Blob $x) { $x.decode("utf-8") }

sub cas-login($username, $password) {
    my $mech = WWW::Mechanize.new(:autocheck);
    #$mech.add_handler("request_send",  ->$r, *@ { note "REQ "~to-str($r.dump); Any; });
    #$mech.add_handler("response_done", ->$r, *@ { note "RESP "~to-str($r.dump); Any; });
    $mech.get: "https://idp.cuni.cz/cas/login?service=https%3A%2F%2Frecodex.mff.cuni.cz%2Fen&renew=true";
    $mech.submit_form(:form_id<fm1>, :fields{ :$username, :$password });

    my $ticket = ~($mech.content ~~ /'"ticket":"' (<-["]>+) '"'/ or fail "bad login")[0];

    $mech.post: "$root/login/cas-uk/oauth", :Content-Type<application/x-www-form-urlencoded>,
                Content => { :$ticket, :clientUrl<https://recodex.mff.cuni.cz/en> };
    my $token = $mech.content.&to-str.&from-json<payload><accessToken>;
    $token;
}

sub login($username, $password) {
    my $resp = post "login", Content => { :$username, :$password };
    $resp<accessToken>;
}

class FileUpload {
    has $.local;
    has $.name = $!local.IO.basename;
    has $.type = "text/plain;charset=UTF-8";
}


sub api-request($meth, $path, *%kw) {
    my %lwp-kw;
    my %form-data = %kw<form-data>:delete // ();
    for %kw.kv -> $_, $val {
        when /^"hdr-"(.*)/ { %lwp-kw{$0.subst("-", "_",:g)} = $val; }
        when /[Content]/ { %lwp-kw{$_} = $val; }
        default { %form-data{$_} = $val; }
    }
    if (%form-data) {
        %lwp-kw<Content> = %form-data.&to-json;
        %lwp-kw<Content_Type> = "application/json";
    }
    note "$meth.uc() $root/$path  {%form-data.&to-json}";
    my $lwp-args = \("$root/$path", Authorization => "Bearer $token", |%lwp-kw);
    #note $lwp-args.perl;
    my $resp = LWP::UserAgent.new."$meth"(|$lwp-args);
    note "RESPONSE " ~ $resp.code ~ " " ~ $resp.content.&to-str.&from-json.&to-json; # pretty print
    if ($resp.code != 200) { die "HTTP error $resp.code()" ~ $resp.content(); }

    my $data = $resp.content.&to-str.&from-json;
    if ($data<code> != 200) { fail "API error: $resp.content()"; }

    $data<payload>;
}

sub get(|args)    { api-request("get",    |args); }
sub post(|args)   { api-request("post",   |args); }
sub delete(|args) { api-request("delete", |args); }
sub put(|args)    { api-request("put",    |args); }

sub save-token($token) {
    $token-file.spurt($token);
}

sub load-token() {
    ($token-file.slurp // return).trim;
}
$token = load-token;

role ApiPrefix {
    method request($meth, $path, |rest) { api-request $meth, "$.prefix/$path", |rest; }
    method get(|args)    { $.request("get",    |args); }
    method post(|args)   { $.request("post",   |args); }
    method delete(|args) { $.request("delete", |args); }
    method put(|args)    { $.request("put",    |args); }
}

# Apply function if value is defined
my method def-apply(Any: &f) { defined(self) ?? f(self) !! self }

class Exercise does ApiPrefix {
    has $.id;
    has $.prefix = "exercises/$!id";
    constant %LANG-TO-ENV = {
        :c<     c-gcc-linux         >,
        :cpp<   cxx-gcc-linux       >,
        :pas<   freepascal-linux    >,
        :cs<    mono                >,
    };
    constant %ENV-TO-LANG = %LANG-TO-ENV.invert.Hash;
    constant %LANG-COMPILE-PIPELINE = {
        c => "GCC Compilation",
        cpp => "G++ Compilation",
        pas => "FreePascal Compilation",
        cs  => "MCS Compilation",
    };
    constant %LANG-STDIO-PIPELINE = {
        cs => "Mono execution & evaluation [stdout]",
        |(<c cpp pas> >>[=>]>> "ELF execution & evaluation [stdout]"),
    };
    constant @DEFAULT-LANGS = <c cpp pas>;
    method setup-envs(@langs = @DEFAULT-LANGS) {
        my %env-defaults;
        for @(get("runtime-environments")) -> $env {
            note $env;
            %env-defaults{$env<id>} = $env;
        }
        my @env-configs;
        for @langs -> $lang {
            my $id = %LANG-TO-ENV{$lang};
            @env-configs.push: { runtimeEnvironmentId => $id,
                                variablesTable => %env-defaults{$id}<defaultVariables> };
        }
        $.post("environment-configs", environmentConfigs => @env-configs);
    }
    method setup-tests($num) {
        $.post("tests", tests => []);
        my @tests = (1..$num).map: { %( name => sprintf("Test %02d", $_), description => "" )  };
        my %test-ids = $.post("tests", :@tests).kv.map( -> $idx, $test { $idx+1 => $test<id> }).Hash;
        note "TEST-IDS %test-ids.perl()";
        my @env-configs;
        my %pipeline-by-name;
        #my %file-hashname = $.list-files.map: { $_<name> => $_<hashName> };
        for @(get("pipelines")) {
            %pipeline-by-name{$_<name>} = $_;
        }
        for $.get("environment-configs")>><runtimeEnvironmentId> -> $env {
            my @tests;
            my $lang = %ENV-TO-LANG{$env};
            for 1..$num -> $idx {
                my $compile-pipeline = {
                    name => %pipeline-by-name{%LANG-COMPILE-PIPELINE{$lang}}<id>,
                    variables => [],
                };
                my ($in-file, $out-file) = ($idx.fmt("%02d.") <<~<< <in out>);
                # .map: { %file-hashname{$_} // die("Cannot find file $_ in task supplementary files") };
                note "LANG_STDIO_PIPELINE $lang $env %LANG-STDIO-PIPELINE{$lang}";
                my $run-pipeline-info = %pipeline-by-name{%LANG-STDIO-PIPELINE{$lang}};
                my @run-vars = @($run-pipeline-info<pipeline><variables>);
                note "RV @run-vars.perl()";
                sub set-var($name, $val) {
                    @run-vars.first({$_<name> eq $name})<value> = $val;
                }
                sub del-var($name) {
                    @run-vars = @run-vars.grep({$_<name> ne $name});
                }
                #set-var "stdin-file", $in-file;
                #set-var "expected-output", $out-file;
                #set-var "actual-inputs", [];
                #del-var "binary-file";
                #del-var "actual-output";
                my $run-pipeline = {
                    name => $run-pipeline-info<id>,
                    variables => #@run-vars,
                    [
                        { :name<stdin-file>,      :value($in-file),             :type<remote-file>   },
                        { :name<expected-output>, :value($out-file),            :type<remote-file>   },
                        { :name<judge-type>,      :value<recodex-judge-normal>, :type<string>        },
                        { :name<custom-judge>,    :value(''),                   :type<remote-file>   },
                        #{ :name<binary-file>,     :value('a.out'),                   :type<file>   },
                        { :name<judge-args>,      :value[],                     :type<string[]>      },
                        { :name<run-args>,        :value[],                     :type<string[]>      },
                        { :name<input-files>,     :value[],                     :type<remote-file[]> },
                        { :name<actual-inputs>,   :value[],                     :type<file[]>        },
                    ]
                };
                my $test = {
                    #name => "Test $idx",
                    name => %test-ids{$idx},
                    pipelines => [$compile-pipeline, $run-pipeline],
                };
                @tests.push($test);
            }
            @env-configs.push: { :name($env), :@tests };
        }
        $.post("config", config => @env-configs);
    }
    # Takes a list of rules in the form
    # {:lang<...>, :test(1..5), :mem(128), :time(0.3)}
    # |----- matchers -------| |------ limits -------|
    #    (smartmatched)          (MB)         (sec)
    # All fields are optionals. First matching rule for
    # given test and limit type wins.
    method setup-limits(@rules) {
        my %test-ids = $.get("tests").kv.map( -> $idx, $test { $idx+1 => $test<id> }).Hash;
        my @langs = %ENV-TO-LANG{ $.get("environment-configs")>><runtimeEnvironmentId>  };
        my $num-tests = +%test-ids;
        my %limits;
        note @rules.perl;
        for (1..$num-tests X @langs) -> $what ($test, $lang) {
            my $rule = @rules.first(-> $rule { all(@$what Z~~ $rule<test lang>) }); # 8-)
            note "  * $what.gist() matched $rule.gist()";
            %limits{$lang}{%test-ids{$test}}<memory wall-time> [Z//]= ($rule<mem>.&def-apply(* * 1024), $rule<time>);
        }
        for @langs -> $lang {
            $.post("environment/%LANG-TO-ENV{$lang}/limits", limits => %limits{$lang});
        }
    }
    #submethod BUILD { $!prefix = "exercises/$!id"; }
    method list-files { $.get("supplementary-files"); }
    method delete-file($name) {
        for $.list-files.grep({ $_<name> eq $name }) {
            $.delete("supplementary-files/$_<id>");
        }
    }
    method upload-file($local, :$name=$local.IO.basename) {
        $.delete-file($name);
        my $upload-resp = post("uploaded-files", :hdr-content-type<form-data>,
                            Content => { $name => [~$local, ~$name, "Content_Type", "text/plain;charset=UTF-8"] });
        my $add-resp = $.post("supplementary-files", files => [$upload-resp<id>] );
        $add-resp.first({$_<name> eq $name});
    }

    method set-judge-arg(@args) {
        my @config := $.get("config");
        for @args.kv -> $test, $arg {
            for @config {
                $_[0]<tests>[$test]<pipelines>[1]<variables>.grep({ $_<name> eq "judge-args" })[0]<value> = [~$arg];
            }
        }
        $.post("config", :@config);
    }
}

multi MAIN("repl") {
    use Debug::REPLHere;
    repl-here;
}

multi MAIN("login", Str $username? is copy, :$cas=False) {
    without $username {
        $*ERR.print: ($cas ?? "CAS " !! "") ~ "Username: ";
        $username = $*IN.get;
    }
    $*ERR.print: ($cas ?? "CAS " !! "") ~ "Password: ";
    my $password = read_password();

    my $token = ($cas ?? &cas-login !! &login)($username, $password);
    unless $token { die "Got empty token"; }
    save-token $token;
}

multi get-exercise-id(Any:U) { %*ENV<RECODEX_TASK> }
multi get-exercise-id(Str:D $task where /[ <.xdigit>+ ] **3..* % '-'/) {
    $task
}
sub get-exercise($task) { Exercise.new(id => get-exercise-id($task)) }
# TODO: lookup by some nicer identifier (store somewhere in metadata)

multi MAIN("upload-file", *@files, :$task) {
    my $ex = get-exercise($task);
    note $ex.prefix;
    $ex.upload-file($_) for @files;
}

multi MAIN("upload-task", $task-id) {


}
