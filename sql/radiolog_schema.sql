create table radiolog (
        frequency varchar(10) not null,
	source varchar(10) not null,
	groups varchar(50),
	time date
);

create trigger insert_radiolog_time after  insert on radiolog
begin
    update radiolog set time = datetime('NOW')  where rowid = new.rowid;
end;
