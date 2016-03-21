CREATE TABLE scores (
	id varchar primary key,
	score_type varchar not null,
	score_value integer,
	engine varchar not null,
	depth bigint not null,
	nodes bigint not null
);

CREATE TABLE clock_info (
	id varchar primary key,
	white_clock integer,
	black_clock integer,
	white_clock_target integer,  -- FIXME: really timestamp with time zone
	black_clock_target integer   -- FIXME: really timestamp with time zone
);

CREATE TABLE current_games (
	id varchar not null primary key,
	json_path varchar not null,
	url varchar not null,
	priority integer not null default 0,
);
