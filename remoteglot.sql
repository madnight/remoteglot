CREATE TABLE scores (
	id varchar primary key,
	plot_score integer not null,
	short_score varchar not null,
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
