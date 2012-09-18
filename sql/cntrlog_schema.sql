create table cntrlog (
        frequency varchar(10) not null,
	source varchar(10) not null,
	time date,
        lat real,
	lon real,
	alt real
);

create trigger insert_log_time after  insert on cntrlog
begin
    update cntrlog set time = datetime('NOW')  where rowid = new.rowid;
end;
