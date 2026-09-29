from colorama import Fore, Style, init

def green_print(msg: str) :
    print(Fore.GREEN + Style.BRIGHT + msg)

def red_print(msg: str) :
    print(Fore.RED + Style.BRIGHT + msg)
