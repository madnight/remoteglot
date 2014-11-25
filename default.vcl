// Varnish configuration snippets.

vcl 4.0;

backend analysis {
    .host = "127.0.0.1";
    .port = "5000";
}

sub vcl_recv {
    if (req.restarts == 0) {
        if (req.http.x-forwarded-for) {
            set req.http.X-Forwarded-For =
                req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }
    if (req.http.host ~ "analysis\.sesse\.net$" && req.url ~ "^/analysis\.pl") {
        set req.backend_hint = analysis;
        return (hash);
    }
}

sub vcl_deliver { 
    if (resp.http.x-analysis) {
        set resp.http.Date = now;
        unset resp.http.X-Varnish;
        unset resp.http.Via;
        unset resp.http.Age;
        unset resp.http.X-Powered-By;
    }
    unset resp.http.x-analysis;
}

sub vcl_hash {
    hash_data(regsub(req.url, "unique=.*$", ""));
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
    return (lookup);
}

sub vcl_backend_response {
    if (bereq.http.host ~ "analysis") {
        set beresp.ttl = 1m;
        if (beresp.http.content-type ~ "text" || beresp.http.content-type ~ "json") {
             set beresp.do_gzip = true;
        }
        if (beresp.http.content-type ~ "json") {
             set beresp.http.x-analysis = 1;
             ban ( "obj.http.x-analysis == 1 && obj.http.x-rglm != " + beresp.http.x-rglm );
        }
        return (deliver);
    }
}
