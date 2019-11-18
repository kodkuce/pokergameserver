CREATE DATABASE gameserverdb;

CREATE TABLE roles( id SERIAL PRIMARY KEY, role TEXT ); 

INSERT INTO roles (role) VALUES ('admin');
INSERT INTO roles (role) VALUES ('player');
  
 CREATE TABLE users ( 
 id SERIAL PRIMARY KEY, 
 nick TEXT NOT NULL, 
 email TEXT NOT NULL, 
 phone TEXT, 
 pass TEXT NOT NULL, 
 activ BOOL NOT NULL DEFAULT false, 
 baned BOOL NOT NULL DEFAULT false, 
 roleid INTEGER NOT NULL REFERENCES roles(id), 
 points BIGINT NOT NULL DEFAULT 0 
 );  


CREATE PROCEDURE remove_points( inout fromwho integer, howmuch integer)
language plpgsql
AS $$
DECLARE
   oldvalue INTEGER := -1;
begin
	select into oldvalue points
	from users
	where id=fromwho;

	if oldvalue >= howmuch then
		update users 
		set points = oldvalue - howmuch
		where id = fromwho;
	else
		fromwho = -1;
	end if;
end $$;


CREATE PROCEDURE add_points( inout fromwho integer, howmuch integer)
language plpgsql
AS $$
begin
	update users 
	set points = points + howmuch
	where id = fromwho;
end $$;