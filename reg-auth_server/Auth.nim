#nimble install libsodium@#head, jwt, pg 
#xbps-install -S libressl-devel or it complains about crypto

# --hint[Pattern]:off

import asynchttpserver, asyncdispatch
import libsodium/sodium_sizes
import libsodium/sodium
import jwt, times, tables
import json, strutils, unicode
import smtp, pg


let CONF = parseJson(readFile("../conf.json"))


var secret_jwt = CONF["appCONF"]["secret_jwt"].getStr()
let pgpool = newAsyncPool( 
  CONF["postgresqlCONF"]["host"].getStr(), 
  CONF["postgresqlCONF"]["user"].getStr(),
  CONF["postgresqlCONF"]["pass"].getStr(),
  CONF["postgresqlCONF"]["dbname"].getStr(),
  CONF["postgresqlCONF"]["connpool"].getInt())



var server = newAsyncHttpServer()


proc validate_username(inputed: JsonNode, errors: var seq[string])=
  if inputed{"username"} == nil:
    errors.add("Missing username")
  else:
    if inputed{"username"}.getStr.len < 5:
      errors.add("Too short username, min 5 chars allowed")
    elif inputed{"username"}.getStr.len > 20:
      errors.add("Too long username, max 20 chars allowed")
    if inputed{"username"}.getStr.isAlpha()==false:
      errors.add("Invalid chars in username, only allowed are a-Z")

proc validate_email(inputed: JsonNode, errors: var seq[string])=
  if inputed{"email"} == nil:
    errors.add("Missing email")
  else:
    if inputed{"email"}.getStr.len < 5 or inputed{"email"}.getStr.contains('@') == false:
      errors.add("Invalid email")

proc validate_password(inputed: JsonNode, errors: var seq[string])=
  if inputed{"password"} == nil:
    errors.add("Missing password")
  else:
    if inputed{"password"}.getStr.len < 9:
      errors.add("Too short password, min 9 chars allowed")
    elif inputed{"password"}.getStr.len > 72:
      errors.add("Too long password, max 72 chars allowed")

proc send_activation_mail(id,email:string){.gcsafe, async.}=
  var atoken = toJWT(%*{
    "header": {
      "alg": "HS256",
      "typ": "JWT"
    },
    "claims": {
      "activateid": id,
      "exp": (getTime() + 1.days).toUnix().int
    }
  })
  atoken.sign(secret_jwt) 

  # echo "---JWT signed token---------------"
  # echo atoken.toString()
  # echo "************"
  # echo $atoken
  # echo "-------------------------------end"


  # try:
  #   let z = verify(atoken, secret_jwt)
  #   echo z
  # except InvalidToken:
  #   echo "Faild to verity"
  # return

  let mailtxt = "Thank you for chosing to play with us, here is your link to activate your account \n" &
                "http://" & CONF["appCONF"]["domain"].getStr() & ":" & CONF["appCONF"]["port"].getStr() &
                "/activate?token=" & atoken.toString

  #echo "wtf1"

  let mailmsg = createMessage("Activate your account", mailtxt, @[email,])
  let senderConn = newAsyncSmtp(useSsl=true, debug=true)
  await senderConn.connect(CONF["smtpCONF"]["server"].getStr(), Port CONF["smtpCONF"]["port"].getInt())
  await senderConn.auth(CONF["smtpCONF"]["user"].getStr(), CONF["smtpCONF"]["pass"].getStr())
  await senderConn.sendMail(CONF["smtpCONF"]["user"].getStr(), @[email,], $mailmsg)
  await senderConn.close()

  #echo "wtf2"

proc cb(req: Request) {.async, gcsafe.} =

  #echo req
  #echo "----------------------------------"

  var errors = newSeq[string]()
  let rheader = newHttpHeaders([("Content-Type","application/json")])

  #REGISTRATION
  if req.url.path=="/reg" and req.reqMethod==HttpPost:

    try:
      let inputed = parseJson(req.body)

      validate_username(inputed, errors)
      validate_password(inputed, errors)
      validate_email(inputed, errors)

      if errors.len() > 0:
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return

      #ok so first we check if account with that email allredy exits
      let row = await pgpool.rows(sql"SELECT 1 FROM users WHERE email=?", @[inputed{"email"}.getStr,])
      if row.len > 0:
        errors.add("Email allready in use")
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return

      #hash pasword
      let hash_password = crypto_pwhash_str(inputed{"password"}.getStr, alg=phaDefault)

      #and if does not we can now create a new user
      let newuserid = await pgpool.rows(sql"INSERT INTO users (nick, email, pass, roleid) VALUES (?,?,?,2) RETURNING id",
                                        @[ inputed["username"].getStr, inputed["email"].getStr, hash_password ])

      #send email with token to new user
      await send_activation_mail( $newuserid[0][0] , inputed["email"].getStr)
      await req.respond(Http200, $(%*{"ok":"Registration successful"}), rheader)
      return

    except JsonParsingError as er:
      errors.add("Recived json in bad format")
      errors.add(er.msg)
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

    except Exception as ex:
      echo ex.msg
      errors.add("Something bad is happening, sorry we are working hard to fix it")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

  #AUTENTIFICATION
  if req.url.path=="/auth" and req.reqMethod==HttpPost:
    
    #echo req

    try:
      let inputed = parseJson(req.body)
      echo inputed
      validate_password(inputed, errors)
      validate_email(inputed, errors)

      if errors.len() > 0:
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return

      #so if input is ok, we check if email exists and compere inputed and db pass
      let gotuser = await pgpool.rows(sql"SELECT users.id, users.pass, users.activ, roles.role, users.points, users.nick FROM users INNER JOIN roles ON users.roleid = roles.id WHERE email = ?", @[inputed["email"].getStr,])
      if gotuser.len>0:#if we found user now need to give him jwtoken so he can use of other services
        # echo gotuser[0][0] #id
        # echo gotuser[0][1] #password
        # echo gotuser[0][2] #active
        # echo gotuser[0][3] #role
        # echo gotuser[0][4] #points
        # echo gotuser[0][5] #nick

        #we need verify password first
        if crypto_pwhash_str_verify(gotuser[0][1], inputed["password"].getStr)==false:
          errors.add("Wrong crediaentals!")
          await req.respond(Http400, $(%*{"error":errors}), rheader)
          return 
        
        #rehash password if needed
        if crypto_pwhash_str_needs_rehash(gotuser[0][1])!=0:
          let rehash_password = crypto_pwhash_str(inputed{"password"}.getStr, alg=phaDefault)
          await pgpool.exec(sql"UPDATE users SET pass=? WHERE id=?", @[rehash_password, gotuser[0][0]])

        #then check if account is activated
        if gotuser[0][2]!="t":
          errors.add("Account not activated, pls first activate account")
          await req.respond(Http400, $(%*{"error":errors}), rheader)
          return 

        var atoken = toJWT(%*{
          "header": {
            "alg": "HS256",
            "typ": "JWT"
          },
          "claims": {
            "id": gotuser[0][0],
            "role": gotuser[0][3],
            "points": gotuser[0][4],
            "nick": gotuser[0][5],
            "exp": (getTime() + 1.days).toUnix().int
          }
        })
        atoken.sign(secret_jwt)
        
        await req.respond(Http200, $(%*{"ok":"Auth successful", "token":atoken}), rheader)
        return

      else: #there is no user with that email
        errors.add("Wrong crediaentals!")
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return 

    except JsonParsingError as er:
      errors.add("Recived json in bad format")
      errors.add(er.msg)
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

    except Exception as ex:
      echo ex.msg
      errors.add("Something bad is happening, sorry we are working hard to fix it")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

  #RESEND ATIVATION EMAIL
  if req.url.path=="/resendemail" and req.reqMethod==HttpPost:
    try:
      let inputed = parseJson(req.body)
      validate_email(inputed, errors)

      if errors.len() > 0:
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return
      
      let userid = await pgpool.rows(sql"SELECT id FROM users WHERE email=?",@[inputed["email"].getStr])
      if userid.len < 1:
        errors.add("No account registred under that email")
        await req.respond(Http400, $(%*{"error":errors}), rheader)
        return

      await send_activation_mail($userid[0][0], inputed["email"].getStr)
      await req.respond(Http200, $(%*{"ok":"Activation code resended successful"}), rheader)
      return
    
    except Exception as ex:
      echo ex.msg
      errors.add("Something bad is happening, sorry we are working hard to fix it")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return
    
  #ACTIVATION BY EMAIL
  if req.url.path=="/activate" and req.reqMethod==HttpGet and req.url.query[0..5]=="token=":
    echo "sombody trying to activate"
    let input_token:string = req.url.query[6..req.url.query.len-1]
    
    try:
      let jwtToken = input_token.toJWT()
      if jwtToken.verify(secret_jwt):
        let actid = $jwtToken.claims["activateid"].node.str
        await pgpool.exec(sql"UPDATE users SET activ = true WHERE id=?", @[actid])
        await req.respond(Http200, $(%*{"ok":"Activation successful"}), rheader)
        return

    except InvalidToken as te:
      errors.add(te.msg) 
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return
    
    except Exception as ex:
      echo ex.msg
      errors.add("Something bad is happening, sorry we are working hard to fix it")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

  #IVALID PATH REQUESTS
  await req.respond(Http404, "Not Found") 

waitFor server.serve(Port(8888), cb)
