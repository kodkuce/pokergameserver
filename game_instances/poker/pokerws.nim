{.experimental: "codeReordering".}
import 
  jwt, times, tables, json, strutils, random, sequtils, algorithm,
  asynchttpserver, asyncdispatch, ws, pg
randomize()



type
  CategoryHand {.pure } = enum
    HighCard, OnePair, TwoPair, Triples, Straight, Flush, FullHouse, Quads, StraightFlush, RoyalFlush

  Status {.pure } = enum
    Empty ,Ready, StartedRound, Folded

  Player* = ref object
    id* : int
    conn* : WebSocket

  Card = ref object
    suit:int
    rank:int

  PlayerSlot = ref object
    player:Player
    p_id:int #stores id for recconection, if player drops out but reconnects before kicked form table or in turnaments
    p_nick:string #so other players can see player nick
    lock:bool #locking player trying to sit on this slot untl request before finishes it
    points:int #points are for betting
    points_round:int #this is points player invested this round
    status:Status
    card_1:Card
    card_2:Card
    best_hand:seq[Card]
    category_hand:CategoryHand
    end_rank:int
    answer:string #answer per asking circle, on ask it gets droped to  "" then server w8s player to fill it or timeout/checkfold

  PokerTable = ref object of RootObj
    deck:seq[Card] #52 cards
    on_t:seq[Card] # cards on table
    blinds:tuple[small,big:int] 
    buyins:tuple[min,max:int]
    player_slots:seq[PlayerSlot]
    dealer_pos:int #who is dealer
    sb_pos:int
    bb_pos:int
    atm_slot:int
    atm_raise:int #how much do other players need to bet to stay inround, ex: i raised raised bet to 1000, now player with 300 must bet 700more or fold/allin
    times_raised:int
    last_raised:int
    delt_cards:seq[int]
    circle_list:seq[PlayerSlot]

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

var pt = PokerTable()
pt.init_table()


proc to_ltext(c:Card):string=
  result = suit_txt[c.suit] & rank_txt[c.rank-2]

proc init_table(pt: var PokerTable)=
  #add player slots
  for i in 0 .. 8:
    var ps = PlayerSlot(player:nil)
    pt.player_slots.add(ps)
  
  #create a deck of cards
  pt.deck.setLen(0)
  for s in 0..3:
    for r in 2..14:
      pt.deck.add( Card(suit:s, rank:r))  

  #seq for circles
  pt.circle_list = newSeq[PlayerSlot]()

proc next_random_card(): int=
  let possible = toSeq(0..51).filterIt( not pt.delt_cards.contains(it) )
  result = possible[rand(possible.len-1)]
  pt.delt_cards.add(result)

proc deal_to_players()=
  pt.delt_cards.setLen(0)
  for i in 0 .. pt.player_slots.high:
    if pt.player_slots[i].status == Status.Ready :
      pt.player_slots[i].card_1 = pt.deck[next_random_card()]
      pt.player_slots[i].card_2 = pt.deck[next_random_card()]
      pt.player_slots[i].status = Status.StartedRound
      if pt.player_slots[i].player != nil:
        #card =  slot - 0..8 players 9 is table,  pos - 0..1 player 0..4 table, suit 0..3, rank 0..12
        asyncCheck pt.player_slots[i].player.conn.send($(%*{"type":"card_info", "cards":[ 
          $i & "0" & $pt.player_slots[i].card_1.suit & $pt.player_slots[i].card_1.rank,
          $i & "1" & $pt.player_slots[i].card_2.suit & $pt.player_slots[i].card_2.rank
          ] }), Opcode.Binary)

proc deal_table_flop()=
  pt.on_t = newSeq[Card](5)
  pt.on_t[0] = pt.deck[next_random_card()]
  pt.on_t[1] = pt.deck[next_random_card()]
  pt.on_t[2] = pt.deck[next_random_card()]

proc deal_table_forth()=
  pt.on_t[3] = pt.deck[next_random_card()]

proc deal_table_fift()=
  pt.on_t[4] = pt.deck[next_random_card()]

proc best_hand_slot(slot:int)=
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

proc best_slot()=
  var processing_list:seq[PlayerSlot]
  for i in 0..pt.player_slots.len()-1:
    if pt.player_slots[i].status == Status.StartedRound:
      best_hand_slot(i)
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


proc player_sit(who:Player, who_nick:string, wanted_slot:int, points:int):Future[string]{.async.}=
  var errors = newSeq[string]()

  if pt.player_slots[wanted_slot].lock == true:
    echo "Some other person is in process of sitting"
    errors.add("Some other person is in process of sitting")

  #lock it to prevent multiple reqest while we w8 responce form db
  pt.player_slots[wanted_slot].lock = true

  echo "Requesting slot ", wanted_slot

  for p in pt.player_slots:
    if p.p_id == who.id:
      echo "Player wants a double seat, wtf"
      errors.add("You allready have a seat on this table")
      pt.player_slots[wanted_slot].lock = false
      return $(%*{"error":errors})

  if pt.player_slots[wanted_slot].p_id > 0:
    echo "Slot allready taken"
    errors.add("Slot allready taken")
    pt.player_slots[wanted_slot].lock = false
    return $(%*{"error":errors})
  
  let ok = await pgpool.rows(sql"Call remove_points(?,?)", @[intToStr(who.id), intToStr(points)])
  if ok[0][0].parseInt() < 0:
    echo ok
    echo "Failed to remove remove points"
    errors.add("Not enought points to sit")
    pt.player_slots[wanted_slot].lock = false
    return $(%*{"error":errors})
  else:
    pt.player_slots[wanted_slot].player = who
    pt.player_slots[wanted_slot].p_id = who.id
    pt.player_slots[wanted_slot].p_nick = who_nick
    pt.player_slots[wanted_slot].points = points
    pt.player_slots[wanted_slot].status = Status.Ready
    result = $(%*{"ok":"sited"})
    pt.player_slots[wanted_slot].lock = false

proc next_player():int=
  for i in toSeq[0..8][pt.atm_slot+1 .. 8] & toSeq[0..8][0 .. pt.atm_slot-1]:
    if pt.player_slots[i].status == StartedRound and pt.player_slots[i].points != 0:
      return i
  echo "ERRRRRROR"
  quit()

proc next_dealer():int=
  for i in toSeq[0..8][pt.dealer_pos+1 .. 8] & toSeq[0..8][0 .. pt.dealer_pos-1]:
    if pt.player_slots[i].status == Ready:
      return i
  echo "ERRRRRROR"
  quit()

proc bet_points(slot:int, amount:int)=
  let diff = amount.clamp(1,pt.player_slots[slot].points)
  pt.player_slots[slot].points_round += diff
  pt.player_slots[slot].points -= diff

proc ask_player(slot:int){.async.}=
  var answer_time = 5000
  send_to_all( $(%*{"type":"ask_player", "slot":slot, "canrise":false}) )
  #pt.player_slots[slot].answer_time = 2000
  pt.player_slots[slot].answer = ""

  if pt.player_slots[slot].points == 0: #meaning he is all in 
    pt.player_slots[slot].answer = $(%*{"type":"player_response", "slot":slot, "answer":"all-in" })
    return

  while pt.player_slots[slot].answer == ""  and  answer_time > 0:
    await sleepAsync(250)#wait timer to exipre or player to give answer
    #pt.player_slots[slot].answer_time -= 250
    answer_time -= 250
    #if pt.player_slots[slot].answer NOT LEGIT then pt.player_slots[slot].answer = ""
  
  if pt.player_slots[slot].answer == "": #player dident reply timer expired
    echo "Tereating it as check/fold"
    if pt.player_slots[slot].points_round < pt.atm_raise:
      echo "has to fold somobody reaised"
      pt.player_slots[slot].answer = $(%*{"type":"player_response", "slot":slot, "answer":"fold" })
      pt.player_slots[slot].status = Folded
    else:
      pt.player_slots[slot].answer = $(%*{"type":"player_response", "slot":slot, "answer":"check" })

proc process_circle(){.async.}=
  pt.times_raised = 0
  pt.atm_slot = next_player()
  await ask_player(pt.atm_slot)
  while true:
    pt.atm_slot = next_player()
    await ask_player(pt.atm_slot)
    if check_circle_finished(): # TODO possible need to move this to ask_player
      break

proc check_circle_finished():bool= # so circle is finished if all but 1 folded or all gived a answer/reply 
  if check_all_folded():           # and we need to check for raises if all player raised to given req or all-in
    return true #TODO BRIDGE TO END GAME

  for p in pt.player_slots:
    #if p.status == StartedRound and p.points != 0 and p.points_round != pt.atm_raise: #ATM DISABLED FOR TESTING
    #    return false
    if p.status == StartedRound and p.answer == "": #still dident circle torugh all
        return false
          
  return true
  
proc check_all_folded():bool=
  var count = 0
  for p in pt.player_slots:
    if p.status == StartedRound:
      count.inc
  if count > 1:
    result = false
  else:
    result = true




proc send_to_all(what:string)=
  for i in 0 .. playerConnections.high:
    if playerConnections[i] != nil:
      asyncCheck playerConnections[i].conn.send(what, Opcode.Binary)


#Manualy packing on connection game data cuz json doNotSerialize is giving me error, and atm dont want to fight with libs
proc get_table_card_info(): seq[string]=
  for c in pt.on_t:
    result.add( $c.suit & $c.rank )

proc push_game_info(taken_connection_slot:int){.async.}= 
  let data =  $(%*{"type":"game-info", "dealer": pt.dealer_pos, "sb": pt.sb_pos, "bb": pt.bb_pos,
              "tcards": get_table_card_info(),
              "player_slots": [
                {
                  "nick": pt.player_slots[0].p_nick,
                  "points": pt.player_slots[0].points,
                  "points_round": pt.player_slots[0].points_round,
                  "status": pt.player_slots[0].status
                },
                {
                  "nick": pt.player_slots[1].p_nick,
                  "points": pt.player_slots[1].points,
                  "points_round": pt.player_slots[1].points_round,
                  "status": pt.player_slots[1].status
                },
                {
                  "nick": pt.player_slots[2].p_nick,
                  "points": pt.player_slots[2].points,
                  "points_round": pt.player_slots[2].points_round,
                  "status": pt.player_slots[2].status
                },
                {
                  "nick": pt.player_slots[3].p_nick,
                  "points": pt.player_slots[3].points,
                  "points_round": pt.player_slots[3].points_round,
                  "status": pt.player_slots[3].status
                },
                {
                  "nick": pt.player_slots[4].p_nick,
                  "points": pt.player_slots[4].points,
                  "points_round": pt.player_slots[4].points_round,
                  "status": pt.player_slots[4].status
                },
                {
                  "nick": pt.player_slots[5].p_nick,
                  "points": pt.player_slots[5].points,
                  "points_round": pt.player_slots[5].points_round,
                  "status": pt.player_slots[5].status
                },
                {
                  "nick": pt.player_slots[6].p_nick,
                  "points": pt.player_slots[6].points,
                  "points_round": pt.player_slots[6].points_round,
                  "status": pt.player_slots[6].status
                },
                {
                  "nick": pt.player_slots[7].p_nick,
                  "points": pt.player_slots[7].points,
                  "points_round": pt.player_slots[7].points_round,
                  "status": pt.player_slots[7].status
                },
                {
                  "nick": pt.player_slots[8].p_nick,
                  "points": pt.player_slots[8].points,
                  "points_round": pt.player_slots[8].points_round,
                  "status": pt.player_slots[8].status
                },
              ]
              })
  await playerConnections[taken_connection_slot].conn.send(data)
  #TODO ZADNJE, TESTIRAM NA KLIKENTU DA LI JE SVE OK



proc run_game_loop() {.async.}= #RADIMO WHILE true i continue
  while true:
    pt.circle_list.setLen(0)

    #check minimum 2 ready player
    for ps in 0 .. pt.player_slots.high:
      if pt.player_slots[ps].status == Ready:
        pt.circle_list.add(pt.player_slots[ps])
    if pt.circle_list.len < 2:
      await sleepAsync(2000)
      echo "Not enought players idling"


      #asyncCheck run_game_loop(); continue
      #return; 
      continue

    #asign dealer
    pt.dealer_pos = next_dealer()

    #deal cards players
    deal_to_players()
    echo "Delt cards"

    #asign blinds
    pt.atm_slot = pt.dealer_pos
    pt.atm_slot = next_player()
    bet_points(pt.atm_slot, pt.blinds[0]) #small
    pt.sb_pos = pt.atm_slot
    pt.atm_slot = next_player()
    bet_points(pt.atm_slot, pt.blinds[1]) #big
    pt.bb_pos = pt.atm_slot

    pt.atm_raise = pt.blinds[1]#set raise to big blind
    

    echo "asigned blinds"
    await sleepAsync(1000)

    #ask circle 1
    await process_circle()
    #check if folded for winings meybe if leave ^^^ here
    echo "ask circle 1 finished"

    #deal flop
    deal_table_flop()
    echo  "dealt flop"

    #ask circle 2
    await process_circle()
    echo "ask circle 2 finished"

    #deal forth
    deal_table_forth()

    #ask circle 3
    await process_circle()
    echo "ask circle 3 finished"

    #deal fift 
    deal_table_fift()

    #ask circle 4
    await process_circle()
    echo "ask circle 4 finished"

    #process cards
    best_slot()
    echo "Figuring out who won"


    var rseq = pt.player_slots.toSeq() #ATM DEBUG CLEAN THIS UP TODO
    #rseq.sort() do (x,y:PlayerSlot) -> int: cmp( y.end_rank, x.end_rank )
    for f in 0 .. rseq.high:
      if rseq[f].best_hand.len > 1:
        echo "Ranked: ", $rseq[f].end_rank, " on slot:", f, " got ", $rseq[f].category_hand, " with cards ", rseq[f].best_hand[0].to_ltext(), rseq[f].best_hand[1].to_ltext(),
              rseq[f].best_hand[2].to_ltext(), rseq[f].best_hand[3].to_ltext(), rseq[f].best_hand[4].to_ltext()


    echo "rund ended"
    
    #cleanup
    for i in 0 .. pt.player_slots.high:
      pt.player_slots[i].best_hand.setLen(0)
      pt.player_slots[i].answer = ""
      pt.player_slots[i].points_round = 0
      if pt.player_slots[i].points == 0:
        pt.player_slots[i].p_id = 0
        pt.player_slots[i].p_nick = ""
        send_to_all( $(%*{"type":"slot-cleared", "slot":i }) )

    #next round




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
  let nick = atoken.claims["nick"].node.str
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
      if playerConnections[i] == nil:
        playerConnections[i] = Player(conn:ws, id: atoken.claims["id"].node.str.parseInt() )
        taken_connection_slot = i
        break


    if taken_connection_slot < 0:
      errors.add("Server is full, sorry")
      await req.respond(Http400, $(%*{"error":errors}), rheader)
      ws.close()
      return

    #reconect check if allreayd sitting TODO

    #give initial data to player
    await push_game_info(taken_connection_slot)


    while ws.readyState == Open:
      let packet = await ws.receiveBinaryPacket()
      echo "--------------------"
      #echo packet
      #echo typeof(packet)

      try:
        var fromjson = parseJson( cast[string](packet) )
        #echo fromjson["type"].getStr()

        case fromjson["type"].getStr():
          of "sitdown":
            await ws.send( await player_sit(playerConnections[taken_connection_slot], nick, fromjson["place"].getInt, fromjson["points"].getInt), Opcode.Binary )
          # of "fold":
          #   for p in pt.player_slots:
          #     if p.player.id == atoken.claims["id"].node.str.parseInt():
          #       p.Status = Foald
          #       break
          #   echo "foldi"
          # of "checkfold":
          #   for p in pt.player_slots:
          #     if p.player.id == atoken.claims["id"].node.str.parseInt():
          #       #p.chek_fold = true
          #       break
          of "player_response":
            echo "c"

        #fold, checkfold, raise, call, check, situp, sitdown, disconnect

      except:
        echo "beh"
      
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
