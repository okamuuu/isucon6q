package Isuda::Web;
use 5.014;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use Encode qw/decode_utf8 encode_utf8/;
use POSIX qw/ceil/;
use Furl;
use JSON::XS qw/decode_json/;
use String::Random qw/random_string/;
use Digest::SHA1 qw/sha1_hex/;
use URI::Escape qw/uri_escape_utf8/;
use Text::Xslate::Util qw/html_escape/;
use List::Util qw/min max/;
use MyProfiler;
use Regexp::Trie;
use Redis::Fast;

my $p = MyProfiler->new();
sub start { $p->start($_[0]) }
sub end   { $p->end($_[0]) }

my $redis = Redis::Fast->new;
sub redis {
    return $redis;
}

my $json = JSON::XS->new->utf8;
sub json {
    return $json;
}

sub config {
    state $conf = {
        dsn           => $ENV{ISUDA_DSN}         // 'dbi:mysql:db=isuda',
        db_user       => $ENV{ISUDA_DB_USER}     // 'root',
        db_password   => $ENV{ISUDA_DB_PASSWORD} // '',
        isutar_origin => $ENV{ISUTAR_ORIGIN}     // 'http://localhost:5001',
        isupam_origin => $ENV{ISUPAM_ORIGIN}     // 'http://localhost:5050',
    };
    my $key = shift;
    my $v = $conf->{$key};
    unless (defined $v) {
        die "config value of $key undefined";
    }
    return $v;
}

sub dbh {
    my ($self) = @_;
    return $self->{dbh} //= DBIx::Sunny->connect(config('dsn'), config('db_user'), config('db_password'), {
        Callbacks => {
            connected => sub {
                my $dbh = shift;
                $dbh->do(q[SET SESSION sql_mode='TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY']);
                $dbh->do('SET NAMES utf8mb4');
                return;
            },
        },
    });
}

filter 'set_name' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        my $user_id = $c->env->{'psgix.session'}->{user_id};
        if ($user_id) {
            $c->stash->{user_id} = $user_id;
            $c->stash->{user_name} = $self->dbh->select_one(q[
                SELECT name FROM user
                WHERE id = ?
            ], $user_id);
            $c->halt(403) unless defined $c->stash->{user_name};
        }
        $app->($self,$c);
    };
};

filter 'authenticate' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        $c->halt(403) unless defined $c->stash->{user_id};
        $app->($self,$c);
    };
};

get '/initialize' => sub {
    my ($self, $c)  = @_;
    $self->dbh->query(q[
        DELETE FROM entry WHERE id > 7101
    ]);
    $self->dbh->query(q[
        TRUNCATE entry_star;
    ]);

    my $entries = $self->dbh->select_all(qq[
        SELECT keyword FROM entry
    ]);
    my $posts = $self->dbh->select_all(qq[ 
        SELECT keyword FROM post
    ]);

    my @keywords = ((map { $_->{keyword} } @$entries), (map { $_->{keyword} } @$posts));
    my $rt = Regexp::Trie->new;
    $rt->add($_) for @keywords;
    my $re = $rt->regexp;
    set_regexp($re);

    $c->render_json({
        result => 'ok',
    });
};

get '/' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;

    my $PER_PAGE = 10;
    my $page = $c->req->parameters->{page} || 1;

    my $entries = $self->dbh->select_all(qq[
        SELECT * FROM entry
        ORDER BY updated_at DESC
        LIMIT $PER_PAGE
        OFFSET @{[ $PER_PAGE * ($page-1) ]}
    ]);
    foreach my $entry (@$entries) {
        if ($entry->{rendered}) {
          $entry->{html}  = $entry->{rendered};
        } else {
          $entry->{html}  = $self->htmlify($c, $entry->{description});
          $self->update_rendered($entry);
        }
        $entry->{stars} = $self->get_entry_stars($entry->{id});
    }

    my $total_entries = $self->dbh->select_one(q[
        SELECT COUNT(*) FROM entry
    ]);
    my $last_page = ceil($total_entries / $PER_PAGE);
    my @pages = (max(1, $page-5)..min($last_page, $page+5));

    $c->render('index.tx', { entries => $entries, page => $page, last_page => $last_page, pages => \@pages });
};

get 'robots.txt' => sub {
    my ($self, $c)  = @_;
    $c->halt(404);
};

post '/keyword' => [qw/set_name authenticate/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->req->parameters->{keyword};
    unless (length $keyword) {
        $c->halt(400, q('keyword' required));
    }
    my $user_id = $c->stash->{user_id};
    my $description = $c->req->parameters->{description};

    if (is_spam_contents($description) || is_spam_contents($keyword)) {
        $c->halt(400, 'SPAM!');
    }

    $self->del_html_by_keyword($keyword);
    $self->save_posted_keyword($keyword);    
    $self->dbh->query(q[
        INSERT INTO entry (author_id, keyword, description, created_at, updated_at)
        VALUES (?, ?, ?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        author_id = ?, keyword = ?, description = ?, updated_at = NOW()
    ], ($user_id, $keyword, $description) x 2);

    $c->redirect('/');
};

get '/register' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;
    $c->render('authenticate.tx', {
        action => 'register',
    });
};

post '/register' => sub {
    my ($self, $c) = @_;

    my $name = $c->req->parameters->{name};
    my $pw   = $c->req->parameters->{password};
    $c->halt(400) if $name eq '' || $pw eq '';

    my $user_id = register($self->dbh, $name, $pw);

    $c->env->{'psgix.session'}->{user_id} = $user_id;
    $c->redirect('/');
};

sub register {
    my ($dbh, $user, $pass) = @_;

    my $salt = random_string('....................');
    $dbh->query(q[
        INSERT INTO user (name, salt, password, created_at)
        VALUES (?, ?, ?, NOW())
    ], $user, $salt, sha1_hex($salt . $pass));

    return $dbh->last_insert_id;
}

get '/login' => [qw/set_name/] => sub {
    my ($self, $c)  = @_;
    $c->render('authenticate.tx', {
        action => 'login',
    });
};

post '/login' => sub {
    my ($self, $c) = @_;

    my $name = $c->req->parameters->{name};
    my $row = $self->dbh->select_row(q[
        SELECT * FROM user
        WHERE name = ?
    ], $name);
    if (!$row || $row->{password} ne sha1_hex($row->{salt}.$c->req->parameters->{password})) {
        $c->halt(403)
    }

    $c->env->{'psgix.session'}->{user_id} = $row->{id};
    $c->redirect('/');
};

get '/logout' => sub {
    my ($self, $c)  = @_;
    $c->env->{'psgix.session'} = {};
    $c->redirect('/');
};

get '/keyword/:keyword' => [qw/set_name/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->args->{keyword} // $c->halt(400);

    my $entry = $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $keyword);
    $c->halt(404) unless $entry;
    if ($entry->{rendered}) {
      $entry->{html}  = $entry->{rendered};
    } else {
      $entry->{html}  = $self->htmlify($c, $entry->{description});
      $self->update_rendered($entry);
    }
    $entry->{stars} = $self->get_entry_stars($entry->{id});

    $c->render('keyword.tx', { entry => $entry });
};

post '/keyword/:keyword' => [qw/set_name authenticate/] => sub {
    my ($self, $c) = @_;
    my $keyword = $c->args->{keyword} or $c->halt(400);
    $c->req->parameters->{delete} or $c->halt(400);

    $c->halt(404) unless $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $keyword);
    
    $self->del_html_by_keyword($keyword);

    $self->dbh->query(qq[
        DELETE FROM entry
        WHERE keyword = ?
    ], $keyword);
    $c->redirect('/');
};

sub htmlify {
    my ($self, $c, $content) = @_;
    return '' unless defined $content;
   
    start('sub htmlify'); 
    # start('sub htmlify -> select keywords');
    # my $entries = $self->dbh->select_all(qq[
    #     SELECT keyword FROM entry
    # ]);
    # end('sub htmlify -> select keywords');

    # start('sub htmlify -> create regex');
    # my $rt = Regexp::Trie->new;
    # for my $entry (@$entries) {
    #   my $re = quotemeta $entry->{keyword};
    #   if ($content =~ /$re/) {
    #     $rt->add($entry->{keyword});
    #   }
    # }
    # my $re = $rt->regexp;
    # end('sub htmlify -> create regex');
 
    my %kw2sha;
    
    # start('sub htmlify -> replace content');
    my $re = get_regexp();
    $content =~ s{($re)}{
        my $kw = $1;
        $kw2sha{$kw} = "isuda_" . sha1_hex(encode_utf8($kw));
    }eg;
    # end('sub htmlify -> replace content');
    
    # start('sub htmlify -> html_escape');
    $content = html_escape($content);
    # end('sub htmlify -> html_escape');

    # start('sub htmlify -> link escape');
    while (my ($kw, $hash) = each %kw2sha) {
        my $url = $c->req->uri_for('/keyword/' . uri_escape_utf8($kw));
        my $link = sprintf '<a href="%s">%s</a>', $url, html_escape($kw);
        $content =~ s/$hash/$link/g;
    }
    # end('sub htmlify -> link escape');

    # start('sub htmlify -> replace br');
    $content =~ s{\n}{<br \/>\n}gr;
    # end('sub htmlify -> replace br');
    end('sub htmlify'); 
    return $content;
}

sub load_stars {
    my ($self, $keyword) = @_;
    my $origin = config('isutar_origin');
    my $url = URI->new("$origin/stars");
    $url->query_form(keyword => $keyword);
    my $ua = Furl->new;
    my $res = $ua->get($url);
    my $data = decode_json $res->content;

    $data->{stars};
}

sub is_spam_contents {
    my $content = shift;
    my $ua = Furl->new;
    my $res = $ua->post(config('isupam_origin'), [], [
        content => encode_utf8($content),
    ]);
    my $data = decode_json $res->content;
    !$data->{valid};
}

sub get_entry_stars {
    my ($self, $entry_id) = @_;
    return $self->dbh->select_all(q[
        SELECT * FROM entry_star WHERE entry_id = ?
    ], $entry_id);
}

get '/stars' => sub {
    my ($self, $c) = @_; 

    my $entry = $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $c->req->parameters->{keyword});

    if (not $entry) {
      return $c->render_json({ stars => [] }); 
    }
    
    my $stars = $self->get_entry_stars($entry->{id});
    $c->render_json({
        stars => $stars,
    }); 
};

post '/stars' => sub {
    my ($self, $c) = @_; 
    my $keyword = $c->req->parameters->{keyword};

    my $entry = $self->dbh->select_row(qq[
        SELECT * FROM entry
        WHERE keyword = ?
    ], $c->req->parameters->{keyword});

    if (not $entry) {
        $c->halt(404);
    }   

    $self->dbh->query(q[
        INSERT INTO entry_star (entry_id, user_name)
        VALUES (?, ?)
    ], $entry->{id}, $c->req->parameters->{user});

    $c->render_json({
        result => 'ok',
    }); 
};

sub set_regexp {
  my ($regex) = @_;
  my $v = encode_utf8($regex);
  redis()->set('regexp', $v);
}

sub get_regexp {
  return decode_utf8(redis()->get('regexp'));
}

sub is_number_words {
  return $_[0] =~ /\d/ ? 1 : 0;
}

sub filter_words {
  my ($words) = @_; 

  my @number_words = (); 
  my @any_words = (); 
  for my $k (@{$words}) {
    if (is_number_words($k)) {
      push(@number_words, $k);
    }   
    else {
      push(@any_words, $k);
    }   
  }

  return (\@number_words, \@any_words);
}

sub create_regexp {
    my ($keywords) = @_;
    my $tr = Regexp::Trie->new;
    $tr->add($_) for @$keywords;
    return $tr->regexp; 
}

get '/hack/html' => sub {
    my ($self, $c)  = @_;

    my $entries = $self->dbh->select_all(qq[
        SELECT id, keyword, description FROM entry WHERE id <= 7101
    ]);

    for my $entry (@$entries) {
      warn $entry->{id};
      my $html = $self->htmlify($c, $entry->{description});
      $self->dbh->query(qq[
        UPDATE entry SET rendered = ? WHERE id = ?
      ], ($html, $entry->{id}));
    }

    $c->render_json({
        "result" => "ok"
    }); 
};

sub update_rendered {
    my ($self, $entry) = @_;
    $self->dbh->query(qq[
      UPDATE entry SET rendered = ? WHERE id = ?
    ], ($entry->{html}, $entry->{id}));
} 

sub del_html_by_keyword {
    my ($self, $keyword) = @_;
    return if not $keyword;
    $self->dbh->query(q[ 
        UPDATE entry SET rendered = NULL WHERE description LIKE ?
    ], ("%" . $keyword . "%"));
}

sub save_posted_keyword {
    my ($self, $keyword) = @_;
    
    $self->dbh->query(q[
        INSERT INTO post (keyword, created_at, updated_at)
        VALUES (?, NOW(), NOW())
        ON DUPLICATE KEY UPDATE
        keyword = ?, updated_at = NOW()
    ], ($keyword) x 2);
}

1;
;
