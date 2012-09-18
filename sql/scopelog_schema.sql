
create table scopepass (
    passid integer primary key autoincrement,
    time date,
    lat real,
    lon real,
    alt real
);

create trigger insert_pass_time after  insert on scopepass
begin
    update scopepass set time = datetime('NOW')  where rowid = new.rowid;
end;



create table scopelog (
    frequency real not null,
    strength integer,
    time date,
    passid integer,
    foreign key(passid) references scopepass(passid),
    primary key (frequency, passid)
);

create trigger insert_log_time after  insert on scopelog
begin
    update scopelog set time = datetime('NOW')  where rowid = new.rowid;
end;

