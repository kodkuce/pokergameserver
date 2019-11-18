import jwt, times, tables, json, strutils, random, sequtils, algorithm
import asynchttpserver, asyncdispatch, ws, pg




randomize()

type
  CategoryHand {.pure } = enum
    HighCard, OnePair, TwoPair, Triples, Straight, Flush, FullHouse, Quads, StraightFlush, RoyalFlush

  Status {.pure } = enum
    Ready, StartedRound, Folded

  Player* = ref object
    id* : int
    conn* : WebSocket

  Card = ref object
    suit:int
    rank:int

  PlayerSlot = ref object
    player:Player
    money:int
    money_round:int
    status:Status
    card_1:Card
    card_2:Card
    best_hand:seq[Card]
    category_hand:CategoryHand
    end_rank:int

  PokerTable = ref object of RootObj
    deck:seq[Card]
    on_t:seq[Card]
    blinds:tuple[small,big:int] 
    buyins:tuple[min,max:int]
    player_slots:seq[PlayerSlot]
    dealer_pos:int
    sb_pos:int
    bb_pos:int
    atm_slot:int
    atm_raise:int
    last_raised:int
    delt_cards:seq[int]
  

const suit_txt = ["♠", "♥", "♦", "♣"]
const rank_txt = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]

var playerConnections = newSeq[Player](500)
let CONF = parseJson(readFile("conf.json"))
var secret_jwt = CONF["appCONF"]["secret_jwt"].getStr()
let pgpool = newAsyncPool( 
  CONF["postgresqlCONF"]["host"].getStr(), 
  CONF["postgresqlCONF"]["user"].getStr(),
  CONF["postgresqlCONF"]["pass"].getStr(),
  CONF["postgresqlCONF"]["dbname"].getStr(),
  CONF["postgresqlCONF"]["connpool"].getInt())


proc ToText(c:Card): string=
  result = suit_txt[c.suit] & rank_txt[c.rank-2]

proc init_table(pt: var PokerTable)=
  for i in 0 .. 8:
    var ps = PlayerSlot(player:nil)
    pt.player_slots.add(ps)

proc deck_fill(pt: var PokerTable)=
  pt.deck.setLen(0)
  for s in 0..3:
    for r in 2..14:
      pt.deck.add( Card(suit:s, rank:r))

proc next_random_card( pt: var PokerTable): int=
  let possible = toSeq(0..51).filterIt( not pt.delt_cards.contains(it) )
  result = possible[rand(possible.len-1)]
  pt.delt_cards.add(result)

proc deal_to_players(pt: var PokerTable)=
  pt.delt_cards.setLen(0)
  for ps in mitems(pt.player_slots):
    if ps.status == Status.Ready :
      ps.card_1 = pt.deck[next_random_card(pt)]
      ps.card_2 = pt.deck[next_random_card(pt)]
      ps.status = Status.StartedRound

proc deal_table_flop(pt: var PokerTable)=
  pt.on_t = newSeq[Card](5)
  pt.on_t[0] = pt.deck[next_random_card(pt)]
  pt.on_t[1] = pt.deck[next_random_card(pt)]
  pt.on_t[2] = pt.deck[next_random_card(pt)]

proc deal_table_forth(pt: var PokerTable)=
  pt.on_t[3] = pt.deck[next_random_card(pt)]

proc deal_table_fift(pt: var PokerTable)=
  pt.on_t[4] = pt.deck[next_random_card(pt)]

proc best_hand_slot(pt: var PokerTable, slot:int)=
  var input_hand:seq[Card] = @[pt.on_t[0], pt.on_t[1], pt.on_t[2], pt.on_t[3], pt.on_t[4], pt.player_slots[slot].card_1, pt.player_slots[slot].card_2]
  var samesuits:seq[Card] = newSeq[Card](0)

  #Check min 5 same symbol
  for samesymbol in 0..3:
    if samesuits.len() >= 5:
      samesuits.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)  #switched form x,y to y,x for reverse
      break #exit loop we have at least 5 same suit

    samesuits.setLen(0) #else empty and try for next symbol
    for i in 0..6:
      if input_hand[i].suit == samesymbol:
        samesuits.add(input_hand[i])

  #ROYAL FLUSH
  if samesuits.len() >= 5:
    if samesuits[0].rank==14 and samesuits[1].rank==13 and samesuits[2].rank==12 and samesuits[3].rank==11 and samesuits[4].rank==10:
      pt.player_slots[slot].best_hand = samesuits[0..4]
      pt.player_slots[slot].category_hand = CategoryHand.RoyalFlush
      return

  #STRAINGHT FLUSH
  if samesuits.len() >= 5:
    for x in 0..samesuits.len()-5: #check cuz it can be  10 8 65432
      if samesuits[x].rank-1 == samesuits[x+1].rank and samesuits[x+1].rank-1 == samesuits[x+2].rank and
      samesuits[x+2].rank-1 == samesuits[x+3].rank and samesuits[x+3].rank-1 == samesuits[x+4].rank:
        pt.player_slots[slot].best_hand = @[ samesuits[x], samesuits[x+1], samesuits[x+2], samesuits[x+3], samesuits[x+4] ]
        pt.player_slots[slot].category_hand = CategoryHand.StraightFlush
        return
    #Ace 2 3 4 5
    if samesuits[0].rank == 14 and samesuits[^1].rank == 2 and samesuits[^2].rank == 3 and samesuits[^3].rank == 4 and samesuits[^4].rank == 5:
      pt.player_slots[slot].best_hand = @[ samesuits[0], samesuits[^1], samesuits[^2], samesuits[^3],  samesuits[^4] ]
      pt.player_slots[slot].category_hand = CategoryHand.StraightFlush

  #QUADS, ake FOUR OF KIND
  var quads_le = input_hand
  var quads:seq[Card] = newSeq[Card](0)
  quads_le.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)

  for i in 0..3: #check 4 tims, cuz in 7 card it can be 4444211 9444422 9944442 9994444
    if quads_le[i].rank == quads_le[i+1].rank and quads_le[i+1].rank == quads_le[i+2].rank and quads_le[i+2].rank ==  quads_le[i+3].rank:
      quads = quads_le[i..i+3]
      #remove quads to get leftowers
      quads_le = quads_le.filter() do (x:Card) -> bool: x notin quads
      quads_le.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)

      pt.player_slots[slot].best_hand = @[ quads[0], quads[1], quads[2], quads[3], quads_le[0] ]
      pt.player_slots[slot].category_hand = CategoryHand.Quads
      return

  #FULL HOUSE
  var triples_le = input_hand
  var triples:seq[Card] = newSeq[Card](0)
  triples_le.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)

  for i in 0..4: #same as quads just 1 more time
    if triples_le[i].rank == triples_le[i+1].rank and triples_le[i+1].rank == triples_le[i+2].rank:
      triples = triples_le[i..i+2]

      #remove triples to get lefowers and break loop so we dont take any more triples
      triples_le = triples_le.filter() do (x:Card) -> bool: x notin triples
      triples_le.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)
      break

  if triples.len>2:#if we allready have triples, we check for full house now
    for l in 0..2: #so i have 4 cards so 0 first check second , 1 second check third, 2 third check forth
      if triples_le[l].rank == triples_le[l+1].rank:
        pt.player_slots[slot].best_hand = @[ triples[0], triples[1], triples[2], triples_le[l], triples_le[l+1] ]
        pt.player_slots[slot].category_hand = CategoryHand.FullHouse
        return


  #FLUSH
  if samesuits.len() >= 5:
    pt.player_slots[slot].best_hand = @[ samesuits[0], samesuits[1], samesuits[2], samesuits[3], samesuits[4] ]
    pt.player_slots[slot].category_hand = CategoryHand.Flush
    return


  #STRAIGHT
  var nodouble = input_hand
  #reverse go down the seq and delete doubles
  for i in countdown(nodouble.len-1, 0, 1):
    for g in countdown(i,0,1):
      if g!=i and nodouble[i].rank == nodouble[g].rank:
        nodouble.delete(i)#TODO ask narimiran tommorow when he in happymood :)
        break
  nodouble.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)
  if nodouble.len() >= 5:
    for i in 0..nodouble.len()-5:
      if  nodouble[i].rank == nodouble[i+1].rank-1 and nodouble[i+1].rank == nodouble[i+2].rank-1 and
      nodouble[i+2].rank == nodouble[i+3].rank-1 and nodouble[i+3].rank == nodouble[i+4].rank-1:
        pt.player_slots[slot].best_hand = @[ nodouble[i], nodouble[i+1], nodouble[i+2], nodouble[i+3], nodouble[i+4] ]
        pt.player_slots[slot].category_hand = CategoryHand.Straight
        return
  #ace low straight
  if nodouble[0].rank==14 and nodouble[^1].rank==2 and nodouble[^2].rank==3 and nodouble[^3].rank==4 and nodouble[^4].rank==5:
    pt.player_slots[slot].best_hand = @[ nodouble[0], nodouble[^1], nodouble[^2], nodouble[^3], nodouble[^4] ]
    pt.player_slots[slot].category_hand = CategoryHand.Straight
    return


  #TRIPLES
  if triples.len() > 2:
    pt.player_slots[slot].best_hand = @[ triples[0], triples[1], triples[2], triples_le[0], triples_le[1] ]
    pt.player_slots[slot].category_hand = CategoryHand.Triples
    return

  #PAIR AND DOUBLE PAIR
  var pairs_le = input_hand
  var pairs:seq[Card] = newSeq[Card](0)
  pairs_le.sort do (x,y:Card) -> int: cmp(y.rank, x.rank)

  for i in 0..5:
    if pairs_le[i].rank == pairs_le[i+1].rank:
      if pairs.len() > 3: #if we have 2 pairs no need to look anymore
        break
      pairs.add(pairs_le[i])
      pairs.add(pairs_le[i+1])
  if pairs.len() > 1:
    pairs_le = pairs_le.filter() do (x:Card) -> bool: x notin pairs

    if pairs.len() > 3:
      pt.player_slots[slot].best_hand = @[ pairs[0], pairs[1], pairs[2], pairs[3], pairs_le[0] ]
      pt.player_slots[slot].category_hand = CategoryHand.TwoPair
      return
    else:
      pt.player_slots[slot].best_hand = @[ pairs[0], pairs[1], pairs_le[0], pairs_le[1], pairs_le[2] ]
      pt.player_slots[slot].category_hand = CategoryHand.OnePair
      return

  #HIGH CARD ONLY
  var byrank = input_hand
  byrank.sort() do (x,y:Card) -> int: cmp(y.rank, x.rank)
  pt.player_slots[slot].best_hand = @[ byrank[0], byrank[1], byrank[2], byrank[3], byrank[4] ]
  pt.player_slots[slot].category_hand = CategoryHand.High_Card

proc best_slot(pt: var PokerTable)=
  var processing_list:seq[PlayerSlot]
  for i in 0..pt.player_slots.len()-1:
    if pt.player_slots[i].status == Status.StartedRound:
      pt.best_hand_slot(i)
      processing_list.add(pt.player_slots[i])

  var endrank=1

  processing_list.sort() do (x,y:PlayerSlot) -> int: cmp( y.category_hand, x.category_hand )

  while processing_list.len()>0:
    var same_cat_count:int = 0

    #so here we check if we have more of same category in a row
    for i in 1..processing_list.len-1:#can compere agains 0 cuz in while and we del 0 element

      if processing_list[0].category_hand == processing_list[i].category_hand:
        same_cat_count = same_cat_count + 1
      else:
        break


    if same_cat_count==0:
      processing_list[0].end_rank = endrank
      processing_list.delete(0)
      endrank = endrank + 1
    else:#we have example 3 players with FullHouse and now we need to figure out how to rank them
      var sameranked = processing_list[0..same_cat_count]

      #so depening of what type FullHouse or Straight we have to sort them difrent
      case sameranked[0].category_hand:
        of CategoryHand.RoyalFlush:
          discard
        of CategoryHand.StraightFlush, CategoryHand.Straight:
          sameranked.sort() do (x,y: PlayerSlot) -> int: cmp( y.best_hand[0].rank, x.best_hand[1].rank )
        of CategoryHand.Quads, CategoryHand.FullHouse:
          sameranked.sort() do (x,y: PlayerSlot) -> int:
            result = cmp( y.best_hand[0].rank, x.best_hand[4].rank )
            if result==0:
              result = cmp( y.best_hand[4].rank, x.best_hand[4].rank)
        of CategoryHand.Flush, CategoryHand.HighCard:
          sameranked.sort() do (x,y: PlayerSlot) -> int:
            result = cmp( y.best_hand[0].rank, x.best_hand[0].rank )
            if result==0:
              result = cmp( y.best_hand[1].rank, x.best_hand[1].rank )
            if result==0:
              result = cmp( y.best_hand[2].rank, x.best_hand[2].rank )
            if result==0:
              result = cmp( y.best_hand[3].rank, x.best_hand[3].rank )
            if result==0:
              result = cmp( y.best_hand[4].rank, x.best_hand[4].rank )
        of CategoryHand.Triples, CategoryHand.TwoPair:
          sameranked.sort() do (x,y: PlayerSlot) -> int:
            result = cmp( y.best_hand[0].rank, x.best_hand[0].rank )
            if result==0:
              result = cmp( y.best_hand[3].rank, x.best_hand[3].rank )
            if result==0:
              result = cmp( y.best_hand[4].rank, x.best_hand[4].rank )
        of CategoryHand.OnePair:
          sameranked.sort() do (x,y: PlayerSlot) -> int:
            result = cmp( y.best_hand[0].rank, x.best_hand[0].rank )
            if result==0:
              result = cmp( y.best_hand[2].rank, x.best_hand[2].rank )
            if result==0:
              result = cmp( y.best_hand[3].rank, x.best_hand[3].rank )
            if result==0:
              result = cmp( y.best_hand[4].rank, x.best_hand[4].rank )

      #now that we have sorted first we need check if tottaly same cards
      sameranked[0].end_rank = endrank

      for i in 1..sameranked.len()-1:
        var samecards:bool = true
        for j in 0..4:
          if sameranked[i].best_hand[j].rank != sameranked[i-1].best_hand[j].rank:
            samecards = false
            break
        if samecards:#so if both have fullhous of 44422 they split pot and have same rank
          sameranked[i].end_rank = sameranked[i-1].end_rank
        else:
          endrank = endrank + 1
          sameranked[i].end_rank = endrank

      processing_list.delete(0,same_cat_count)
      endrank = endrank + 1

proc player_sit(pt: var PokerTable, who:Player, wanted_slot:int, points:int){.async, gcsafe.}=
  var errors = newSeq[string]()

  if pt.player_slots[wanted_slot].player != nil:
    echo "Slot allready taken"
  
  let ok = await pgpool.rows(sql"Call remove_points(?,?)", @[intToStr(who.id), intToStr(points)])
  if ok[0][0].parseInt() < 0:
    echo "Failed to remove remove points"
  else:
    pt.player_slots[wanted_slot].player = who
    pt.player_slots[wanted_slot].money = points
    pt.player_slots[wanted_slot].status = Status.Ready



var pokert = PokerTable()
pokert.init_table()

proc run_game_loop() {.async.}=
  #check minimum 2 ready player
  var cnt = 0
  for p in pokert.player_slots:
    if p.status == Status.Ready:
      cnt = cnt + 1
  if cnt < 2:
    await sleepAsync(2000)
    echo "Not enought players"
    asyncCheck run_game_loop();
    return;

  #if more then too start game
  for p in 0 .. pokert.player_slots.len-1:
    echo p




var server = newAsyncHttpServer()
proc cb(req: Request) {.async, gcsafe.} =


  var errors = newSeq[string]()
  let rheader = newHttpHeaders([("Content-Type","application/json")])
  #echo req
  echo req.headers["Authorization"]


  if not req.headers.hasKey("Authorization"):
    errors.add("No authorization header")
    await req.respond(Http400, $(%*{"error":errors}), rheader)
    return

  let atoken = req.headers["Authorization"].toString().toJWT()
  var taken_connection_slot:int = -1


  try:
    if not verify(atoken, secret_jwt):
      errors.add("Token dident pass verification")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      return

  except InvalidToken:
    errors.add("Token is invalid")
    await req.respond(Http400, $(%*{"error":errors}), rheader)
    return


  try:
    var ws = await newWebSocket(req)
    await ws.send("Welcome to simple echo server")


    #find first slot and asign player to it
    for i in 0 .. playerConnections.high:
      echo "z"
      if playerConnections[i] == nil:
        echo "zz"
        playerConnections[i] = Player(conn:ws, id: atoken.claims["id"].node.str.parseInt() )
        #playerConnections[i].conn = ws
        echo "zzz"
        #playerConnections[i].id = atoken.claims["id"].node.str.parseInt()
        echo "zzzz"
        taken_connection_slot = i
        break

    echo "1111"

    if taken_connection_slot < 0:
      errors.add("Server is full, sorry")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      ws.close()
      return


    while ws.readyState == Open:
      let packet = await ws.receiveBinaryPacket()
      echo "--------------------"
      #echo packet
      #echo typeof(packet)

      try:
        var izjsona = parseJson( cast[string](packet) )
        echo izjsona["type"].getStr()

        case izjsona["type"].getStr():
          of "sitdown":
            await pokert.player_sit(playerConnections[taken_connection_slot], izjsona["place"].getInt, izjsona["points"].getInt)
        #fold, raise, call, check, situp, sitdown, disconnect

      except:
        echo "beh"
      


      case packet.join():
        of "1":
          echo "got 1"
        else:
          echo packet 
          waitFor ws.send("Echoing: " & cast[string](packet), Opcode.Binary)        

  except:
    let expmsg = getCurrentExceptionMsg()
    errors.add(expmsg)
    echo ".. socket went away bad"
    await req.respond(Http400, $(%*{"error":errors}), rheader)

  playerConnections[taken_connection_slot] = nil
  

asyncCheck run_game_loop()
asyncCheck server.serve(Port(CONF["appCONF"]["port"].getint()), cb)
runForever()
