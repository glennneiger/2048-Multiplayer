//
//  GameBrain.swift
//  Edwin
//
//  Created by Vegard Solheim Theriault on 28/02/15.
//  Copyright (c) 2015 Wrong Bag. All rights reserved.
//

import Foundation

// After a call to moveInDirection(...), moveTileFromCoordinate will be called
// repeatedly until all the tiles that require moving have been moved.
// After that, any tiles that should merge will be on top of each other.
// For these tiles, mergeTilesAtCoordinate will be called.
protocol GameBrainDelegate: class {
    
    associatedtype D: Evolvable
    
    func gameBrainDidProduceActions(actions: [MoveAction<D>], forSetup: Bool)
    func gameBrainUserHasNewScore(newUserScore: Int)
    func gameBrainOpponentHasNewScore(newOpponentScore: Int)
    func gameBrainDidChangeTurnTo(currentTurn: Turn)
    func gameBrainGameIsOverFromFillingUpBoard()
    
    func gameBrainWillCreateMultiplayerGame()
    func gameBrainDidCreateMultiplayerGameWithGamepin(gamePin: String)
    func gameBrainDidJoinGame()
    
    func gameBrainDidCreateSinglePlayerGame()
    
    func gameBrainDidGetOpponentNamed(opponentName: String)

}

enum Turn {
    case User
    case Opponent
}

class GameBrain<E: GameBrainDelegate>: GameDelegate, GameCreatorDelegate, GameBoardDelegate {

    typealias F = E.D
    typealias A = F
    
    private(set) var userScore = 0 // Public getter, private setter
    private(set) var opponentScore = 0  // Public getter, private setter
    private weak var delegate: E?
    private var gameBoard: GameBoard<GameBrain>!
    
    private var gameServer: GameServerManager!
    private var gameSetup: GameSetup<F>!
    
    private(set) var currentPlayer: Turn = Turn.User { // Public getter, private setter
        didSet {
            if currentPlayer == Turn.User {
                MOONLog("Changed current player to \"User\"")
            } else {
                MOONLog("Changed current player to \"Opponent\"")
            }
            self.delegate?.gameBrainDidChangeTurnTo(self.currentPlayer)
        }
    }
    
    private(set) var gamePin: String? = nil { // Public getter, private setter
        didSet {
            if let gamePin = gamePin {
                self.delegate?.gameBrainDidCreateMultiplayerGameWithGamepin(gamePin)
            }
        }
    }
    
    private(set) var opponentDisplayName: String? = nil { // Will only be set when the game is starting
        didSet {
            if let opponentDisplayName = opponentDisplayName {
                self.delegate?.gameBrainDidGetOpponentNamed(opponentDisplayName)
            }
        }
    }
    
    let userDisplayName: String = UserServerManager.lastKnownCurrentUserDisplayName
    
    private(set) var gameIsOver = false // Will be set to true when there are no more legal moves
    
    
    
    
    
    init(delegate: E?) {
        self.delegate = delegate
    } 
    
    func moveInDirection(direction: MoveDirection) {
        let (scoreIncrease, actions): (Int, [MoveAction<F>]) = self.gameBoard.moveInDirection(direction)
        if actions.count > 0 {
            
            let (spawn, gameOver) = self.gameBoard.spawnNewGamePieceAtRandomPosition()
            if let spawn = spawn {
                
                self.delegate?.gameBrainDidProduceActions(actions, forSetup: false)
                self.delegate?.gameBrainDidProduceActions([spawn], forSetup: false)
                
                if gameSetup.players == Players.Multi {
                    
                    MOONLog("Multi player game")
                    
                    userScore += scoreIncrease
                    self.delegate?.gameBrainUserHasNewScore(userScore)
                    currentPlayer = Turn.Opponent
                    
                    // Have to do switch case to unwrap associated value
                    switch spawn {
                    case let .Spawn(gamePiece):
                        MOONLog("Letting server know about new LastMove")
                        gameServer.performedMoveInDirection(direction,
                            whichSpawnedTile: gamePiece.value,
                            atCoordinate: gamePiece.position)
                    default: break
                    }
                } else if gameSetup.players == Players.Single {
                    MOONLog("Single Player game")
                    userScore += scoreIncrease
                    self.delegate?.gameBrainUserHasNewScore(userScore)
                }
            } else {
                MOONLog("ERROR: Could not spawn")
            }
            
            if gameOver {
                MOONLog("The game is over")
                gameIsOver = true
                self.delegate?.gameBrainGameIsOverFromFillingUpBoard()
            } else {
                MOONLog("The game is not over yet")
            }
            
        } else {
            MOONLog("ERROR: That is not a legal move")
        }
    }
    
    func deleteCurrentGame() {
        if let gamePinString = self.gamePin, gamePinInt = Int(gamePinString) {
            self.gameServer.deleteEventWithGamepin(gamePinInt)
        }
    }
    
    
    
    
    // -------------------------------
    // MARK: Prepare for game
    // -------------------------------
    
    func prepareForGameWithSetup(inout gameSetup: GameSetup<F>) {
        self.gameSetup = gameSetup
        self.gameBoard = GameBoard<GameBrain>(dimension: gameSetup.dimension)
        
        if gameSetup.setupForCreating {
            MOONLog("Setting up for creating")
            
            self.currentPlayer = Turn.User
            
            // No point in checking gameOver. The game has after all just started
            let (firstSpawnAction, _) = self.gameBoard.spawnNewGamePieceAtRandomPosition()
            if let firstSpawnAction  =  firstSpawnAction {
                let (secondSpawnAction, _) = self.gameBoard.spawnNewGamePieceAtRandomPosition()
                if let secondSpawnAction = secondSpawnAction {
                    
                    self.gameServer = GameServerManager()
                    self.gameServer.gameDelegate = self
                    self.gameServer.creatorDelegate = self
                    
                    // Need to do this through switch case for the moment
                    switch firstSpawnAction {
                    case let .Spawn(gamePiece):
                        self.gameSetup.firstTile = gamePiece.value
                        self.gameSetup.firstCoordinate = gamePiece.position
                    default: break
                    }
                    
                    switch secondSpawnAction {
                    case let .Spawn(gamePiece):
                        self.gameSetup.secondTile = gamePiece.value
                        self.gameSetup.secondCoordinate = gamePiece.position
                    default: break
                    }
                    
                    if gameSetup.players == Players.Multi {
                        self.delegate?.gameBrainWillCreateMultiplayerGame()

                        
                        let genericTypeProvider = F(scoreValue: F.getBaseValue().scoreValue)
                        self.gameServer.createGameWithDimension(genericTypeProvider, dimension: gameSetup.dimension, turnDuration: gameSetup.turnDuration,
                            completionHandler: { (gamePin: Int?, errorMessage: String?) -> () in
                                if let error = errorMessage {
                                    MOONLog("ERROR: Got error from createGame: \(error)")
                                } else if let gamePin = gamePin {
                                    MOONLog("Got gamePin: \(gamePin)")
                                    self.gamePin = "\(gamePin)"
                                } else {
                                    MOONLog("WTF!?! There was no error, and no gamepin returned from createGameWithDimension")
                                }
                            })
                    } else {
                        self.delegate?.gameBrainDidCreateSinglePlayerGame()
                    }
                    
                    let spawnActions = [firstSpawnAction, secondSpawnAction]
                    self.delegate?.gameBrainDidProduceActions(spawnActions, forSetup: true)
                } else {
                    MOONLog("ERROR: Could not spawn second random tile")
                }
            } else {
                MOONLog("ERROR: Could not spawn first random tile")
            }
        } else {
            MOONLog("Setting up for joining")
            // Setup for joining, implied that it's a Players.Multi game
            
            self.currentPlayer = Turn.Opponent
            self.opponentDisplayName = gameSetup.opponentDisplayName
            self.gameServer = gameSetup.gameServer
            self.gameServer.gameDelegate = self
            
            // No point in checking gameOver. The game has after all just started
            let (firstSpawn, _) = self.gameBoard.spawnNodeWithValue(gameSetup.firstTile, atCoordinate: gameSetup.firstCoordinate)
            if let firstSpawn = firstSpawn {
                let (secondSpawn, _) = self.gameBoard.spawnNodeWithValue(gameSetup.secondTile, atCoordinate: gameSetup.secondCoordinate)
                if let secondSpawn = secondSpawn {
                    let spawns = [firstSpawn, secondSpawn]
                    self.delegate?.gameBrainDidProduceActions(spawns, forSetup: true)
                    self.delegate?.gameBrainDidJoinGame()
                    MOONLog("Finished joining game")
                } else {
                    MOONLog("ERROR: Could not spawn second planned tile")
                }
            } else {
                MOONLog("ERROR: Could not spawn first planned tile")
            }
        }
    }
    
    func addInitialState(tileOne: MoveAction<F>, tileTwo: MoveAction<F>) {
        
        // This is currently the only way to get associated values out of enums in Swift
        var valueOne: F! = nil
        var coordinateOne: Coordinate! = nil
        switch tileOne {
        case let .Spawn(gamePiece):
            valueOne = gamePiece.value
            coordinateOne = gamePiece.position
        default: break
        }
        
        var valueTwo: F! = nil
        var coordinateTwo: Coordinate! = nil
        switch tileTwo {
        case let .Spawn(gamePiece):
            valueTwo = gamePiece.value
            coordinateTwo = gamePiece.position
        default: break
        }
        
        gameServer.addInitialStateToCurrentGame(
            firstTile: valueOne,
            hasCoordinate: coordinateOne,
            secondTile: valueTwo,
            hasCoordinate: coordinateTwo)
            { (errorMessage: String?) -> () in
                MOONLog("ERROR: Got error while adding initial state to Firebase. Error Message: \(errorMessage)")
            }
    }
    
    
    
    
    // -------------------------------
    // MARK: Game Delegate
    // -------------------------------
    
    func opponentDidPerformMoveInDirection<T: Evolvable>(direction: MoveDirection, whichSpawnedTile newTile: T, atCoordinate coordinate: Coordinate)
    {
        // Do direction first
        // Then spawn
        // Send direction to VC
        // Send spawn to VC
        
        MOONLog("Received direction: \(direction), spawnCoordinate: \(coordinate), spawnValue: \(newTile)")
        
        let (scoreIncrease, actions): (Int, [MoveAction<F>]) = self.gameBoard.moveInDirection(direction)
        
        let (spawnAction, gameOverFromSpawn) = self.gameBoard.spawnNodeWithValue(newTile as! F, atCoordinate: coordinate)
        if let spawnAction = spawnAction {
            
            MOONLog("Will notify GameVC \(self.delegate) about new actions")
            
            self.delegate?.gameBrainDidProduceActions(actions, forSetup: false)
            self.delegate?.gameBrainDidProduceActions([spawnAction], forSetup: false)

            opponentScore += scoreIncrease
            self.delegate?.gameBrainOpponentHasNewScore(opponentScore)
            currentPlayer = Turn.User
        } else {
            MOONLog("ERROR: Could not spawn tile")
        }
        
        if gameOverFromSpawn {
            MOONLog("The game is over")
            gameIsOver = true
            self.delegate?.gameBrainGameIsOverFromFillingUpBoard()
        } else {
            MOONLog("The game is not over yet")
        }
    }
    
    
    
    
    // -------------------------------
    // MARK: Game Creator Delegate
    // -------------------------------
    
    func gotOpponentWithDisplayName(displayName: String) {
        self.opponentDisplayName = displayName
    }

}
