package Arcaeme;

import javax.swing.JTextArea;

/**
 *
 * @author Brian
 */
public class ManaPool {
    private int mana;
    
    public ManaPool(JTextArea manaMax) {
        this.mana = 0;
    }
    
    public void addMana(int x) {
            this.mana += x;
    }
    
    public boolean manaCheck(int max) {
        if (this.mana < max) {
            return true;
        } else {
            return false;
        }
    }
    
    public int getManaPool() {
        return this.mana;
    }
    
}
