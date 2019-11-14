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

  