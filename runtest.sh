DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

cd $DIR/reg-auth_server/
./Auth &
cd $DIR/game_instances/poker/
./pokerws