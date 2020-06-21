{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
module Main where

import Control.Monad
import Options.Commander 
import Prelude
import System.Directory
import System.Process hiding (env)
import Data.List
import Text.Read
import System.Exit
import Data.Either

type TaskManager
  = Named "task-manager"
  & ("help" & Raw
  + Env 'Optional "TASK_DIRECTORY" FilePath
    & ("edit"  & TaskProgram
     + "open"  & TaskProgram
     + "close" & TaskProgram
     + "tasks" & Raw
     + "priorities" & Raw
     + Raw
    )
  )

type TaskProgram = Arg "task-name" String & Raw
  
taskManager :: ProgramT TaskManager IO ()
taskManager = toplevel @"task-manager" . envOptDef @"TASK_DIRECTORY" "tasks" $ \tasksFilePath -> 
      sub @"edit" (editTask tasksFilePath) 
  <+> sub @"open" (newTask tasksFilePath)
  <+> sub @"close" (closeTask tasksFilePath)
  <+> sub @"tasks" (listTasks tasksFilePath)
  <+> sub @"priorities" (listPriorities tasksFilePath)
  <+> hoist describeTaskManager (usage @TaskManager)
  where
    describeTaskManager :: IO a -> IO a
    describeTaskManager io = do
      putStrLn "Welcome to the Task Manager! This is a tool to help you manage tasks, each with priorities."
      io

editTask tasksFilePath = arg @"task-name" $ \taskName -> raw 
  $ withTask tasksFilePath taskName $ \Context{home} task -> callProcess "vim" [home ++ "/" <> tasksFilePath <> "/" ++ taskName ++ ".task"]

newTask tasksFilePath = arg @"task-name" $ \taskName -> raw $ do
  Context{home, tasks} <- initializeOrFetch tasksFilePath
  if not (taskName `elem` tasks)
    then do
      let path = home ++ "/" <> tasksFilePath <> "/" ++ taskName ++ ".task"
      callProcess "touch" [path]
      appendFile path (renderPriorities $ [])
      callProcess "vim" [path]
    else putStrLn $ "task " ++ taskName ++ " already exists."

closeTask tasksFilePath = arg @"task-name" $ \taskName -> raw 
  $ withTask tasksFilePath taskName $ \Context{home, tasks} mtask ->
    case mtask of
      Just Task{priorities} ->
        if priorities == [] 
          then removeFile (home ++ "/" <> tasksFilePath <> "/" ++ taskName ++ ".task")
          else putStrLn $ "task " ++ taskName ++ " has remaining priorities."
      Nothing -> putStrLn "task is corrupted"

listTasks tasksFilePath = raw $ do
  Context{tasks} <- initializeOrFetch tasksFilePath
  mapM_ putStrLn tasks

listPriorities tasksFilePath = raw $ do
  Context{tasks} <- initializeOrFetch tasksFilePath
  forM_ tasks $ \taskName -> withTask tasksFilePath taskName $ \_ mtask -> 
    case mtask of
      Just Task{name, priorities} -> do
        putStrLn $ name ++ ": "
        putStrLn $ renderPriorities priorities
      Nothing -> putStrLn $ "Corruption! Task " ++ taskName ++ " is the culprint"

data Context = Context
  { home :: FilePath
  , tasks :: [String] }
  deriving Show

data Task = Task
  { name :: String
  , priorities :: [(String, String)]
  } deriving (Show, Read)

readTask :: FilePath -> String -> IO (Maybe Task)
readTask tasksFilePath taskName = do
  Context{home, tasks} <- initializeOrFetch tasksFilePath
  if taskName `elem` tasks
    then do
      let path = home ++ "/" <> tasksFilePath <> "/" ++ taskName ++ ".task"
      stringTask <- readFile path
      return $ parseTask taskName stringTask
    else do
      putStrLn $ "task " ++ taskName ++ " does not exist."
      exitSuccess

writeTask :: FilePath -> Task -> IO ()
writeTask tasksFilePath Task{name, priorities} = do
  Context{home, tasks} <- initializeOrFetch tasksFilePath
  let path = home ++ "/" <> tasksFilePath <> "/" ++ name ++ ".task"
  writeFile path $ renderPriorities priorities

renderPriorities :: [(String, String)] -> String
renderPriorities = concat . map (\(x, y) -> ("#" ++ x ++ "\n" ++ unlines (map ("  " ++) $ lines y)))

trimWhitespace :: String -> String
trimWhitespace = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

parseTask :: String -> String -> Maybe Task
parseTask taskName
  = sectionByPriority
      . dropWhile isRight
      . map (\case
      ('#': (trimWhitespace -> xs)) -> Left xs
      xs -> Right xs)
      . lines
    where
      sectionByPriority :: [Either String String] -> Maybe Task
      sectionByPriority = \case
        Left priority : xs -> do
          let (concat . map (fromRight undefined) -> description, xs') = span isRight xs
          Task{priorities} <- sectionByPriority xs'
          Just $ Task taskName ((priority, description) : priorities)
        Right _ : xs -> Nothing
        [] -> Just $ Task taskName []

withTask :: FilePath -> String -> (Context -> Maybe Task -> IO ()) -> IO ()
withTask tasksFilePath taskName action = do
  c@Context{tasks, home} <- initializeOrFetch tasksFilePath
  if taskName `elem` tasks 
    then do
      readTask tasksFilePath taskName >>= \case
        Just task -> action c (Just task)
        Nothing -> action c Nothing
    else putStrLn $ "task " ++ taskName ++ " does not exist."

initializeOrFetch :: FilePath -> IO Context
initializeOrFetch tasksFilePath = do
  home <- getHomeDirectory >>= makeAbsolute
  withCurrentDirectory home $ do
    doesDirectoryExist tasksFilePath >>= \case
      True -> Context home . map (takeWhile (/= '.')) . filter (".task" `isSuffixOf`) <$> listDirectory tasksFilePath
      False -> Context home [] <$ createDirectory tasksFilePath
  
main :: IO ()
main = command_ taskManager
