import Navbar from "./components/Navbar/Navbar";
import Paths from "./Routes/Paths";
import { useEffect } from "react";
import { useDispatch, useSelector } from "react-redux";
import { graphActions } from "./store/graph";

function App() {
  const dispatch = useDispatch();
  const isConnected = useSelector((state) => state.auth.isConnected);
  let priceHistory;


  useEffect(() => {
    (async function () {
      const data = await fetch("https://liqui.onrender.com/api/pricehistory");
      const response = await data.json();
      const history = [...response.data.history];

        priceHistory = history.map((singleHistory) => {
        return singleHistory.price;
      });
      dispatch(graphActions.storeData(priceHistory));
    })();

  }, [isConnected]);

  return (
    <div>
    <Navbar />
    <Paths />
    </div>
  );
}

export default App;
